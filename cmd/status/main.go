// Package main provides the mo status command for real-time system monitoring.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const (
	refreshInterval      = time.Second
	processWatchInterval = refreshInterval
	slowRefreshInterval  = 30 * time.Second
)

var (
	// Command-line flags
	jsonOutput       = flag.Bool("json", false, "exibe as métricas em JSON em vez da TUI")
	procCPUThreshold = flag.Float64("proc-cpu-threshold", 100, "alerta quando um processo fica acima deste percentual de CPU")
	procCPUWindow    = flag.Duration("proc-cpu-window", 5*time.Minute, "duração contínua acima do limite de CPU para um processo")
	procCPUAlerts    = flag.Bool("proc-cpu-alerts", true, "ativa alertas persistentes de processos com CPU alta")

	// Watch mode: stream NDJSON (one snapshot per line) from a single warm collector.
	watchMode     = flag.Bool("watch", false, "transmite métricas continuamente como JSON delimitado por linhas, em vez da TUI/JSON único")
	watchInterval = flag.String("interval", "", "com --watch, intervalo de coleta (ex.: 1s, 2s); padrão 1s")
)

func shouldUseJSONOutput(forceJSON bool, stdout *os.File) bool {
	if forceJSON {
		return true
	}
	if stdout == nil {
		return false
	}
	info, err := stdout.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) == 0
}

type tickMsg struct{}
type animTickMsg struct{}

type model struct {
	collector     *Collector
	width         int
	height        int
	metrics       MetricsSnapshot
	errMessage    string
	schedule      collectionSchedule
	fullCollected bool
	lastUpdated   time.Time
	collecting    bool
	animFrame     int
	catHidden     bool // true = hidden, false = visible
	game          *snakeGame
	cpuHist       []float64
	memHist       []float64
	snakeOpen     bool // S abre/fecha o jogo, que ocupa metade da tela
	cpuCores      int  // how many CPU cores to list; 0 = all
}

// padViewToHeight ensures the rendered frame always overwrites the full
// terminal region by padding with empty lines up to the current height.
func padViewToHeight(view string, height int) string {
	if height <= 0 {
		return view
	}

	contentHeight := lipgloss.Height(view)
	if contentHeight >= height {
		return view
	}

	return view + strings.Repeat("\n", height-contentHeight)
}

func newModel() model {
	return model{
		collector: NewCollector(processWatchOptionsFromFlags()),
		catHidden: loadCatHidden(),
		game:      newSnakeGame(snakeMinCols, snakeMinRows),
		cpuCores:  loadCPUCores(),
	}
}

func processWatchOptionsFromFlags() ProcessWatchOptions {
	return ProcessWatchOptions{
		Enabled:      *procCPUAlerts,
		CPUThreshold: *procCPUThreshold,
		Window:       *procCPUWindow,
	}
}

func validateFlags() error {
	if *procCPUThreshold < 0 {
		return fmt.Errorf("--proc-cpu-threshold deve ser >= 0")
	}
	if *procCPUWindow <= 0 {
		return fmt.Errorf("--proc-cpu-window deve ser > 0")
	}
	return nil
}

func (m model) Init() tea.Cmd {
	return tea.Batch(tickAfter(0), animTick(), snakeTick())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "k":
			// Toggle the snake game (formerly the cat) visibility and persist preference
			m.catHidden = !m.catHidden
			saveCatHidden(m.catHidden)
			return m, nil
		case "up", "down", "left", "right", "w", "a", "d", "r", " ", "enter":
			if m.snakeOpen && m.game != nil {
				m.game.handleKey(msg.String())
			}
			return m, nil
		case "s":
			m.snakeOpen = !m.snakeOpen
			return m, nil
		case "c":
			// Cycle how many CPU cores the card lists (2 → 4 → 8 → all) and persist.
			m.cpuCores = nextCPUCores(m.cpuCores)
			saveCPUCores(m.cpuCores)
			return m, nil
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case tickMsg:
		if m.collecting {
			return m, nil
		}
		m.collecting = true
		return m, m.collectCmd(m.schedule.nextMode(time.Now()))
	case collectionResult:
		if msg.err != nil {
			m.errMessage = msg.err.Error()
		} else {
			m.errMessage = ""
		}
		if !msg.data.CollectedAt.IsZero() {
			m.metrics = msg.data
			m.lastUpdated = msg.data.CollectedAt
			m.cpuHist = appendHistory(m.cpuHist, msg.data.CPU.Usage)
			m.memHist = appendHistory(m.memHist, msg.data.Memory.UsedPercent)
		}
		if msg.mode == collectionFull && msg.err == nil {
			m.fullCollected = true
		}
		m.collecting = false
		delay := m.schedule.recordCompletion(msg, refreshInterval)
		return m, tickAfter(delay)
	case snakeTickMsg:
		if m.snakeOpen && m.game != nil {
			m.game.step()
		}
		return m, snakeTick()
	case animTickMsg:
		m.animFrame++
		return m, animTickWithSpeed(m.metrics.CPU.Usage)
	}
	return m, nil
}

func (m model) View() string {
	if !m.schedule.hasSnapshot {
		return "Carregando..."
	}

	termWidth := m.width
	if termWidth <= 0 {
		termWidth = 80
	}

	header, mole := renderHeader(m.metrics, m.errMessage, m.animFrame, termWidth, m.catHidden)
	// The game only exists while S has it open; the old mole sprite is gone.
	mole = ""
	if m.snakeOpen {
		if m.game == nil {
			m.game = newSnakeGame(snakeMinCols, snakeMinRows)
		}
		m.game.ensureSize(snakeSizeFor(termWidth, m.height))
		mole = m.game.render()
	}
	alertBar := renderProcessAlertBar(
		m.metrics.ProcessAlerts,
		m.metrics.ProcessStale,
		m.metrics.ProcessCollectedAt,
		termWidth,
	)

	renderFrame := func(cpuCores int) string {
		var cardContent string
		if termWidth <= 80 {
			cardWidth := termWidth
			if cardWidth > 2 {
				cardWidth -= 2
			}
			cards := buildCards(m.metrics, cardWidth, cpuCores, m.fullCollected)
			cards = append(cards, renderHistoryCard(m.cpuHist, m.memHist, m.metrics, cardWidth))

			var rendered []string
			for i, c := range cards {
				if i > 0 {
					rendered = append(rendered, "")
				}
				rendered = append(rendered, renderCard(c, cardWidth))
			}
			cardContent = lipgloss.JoinVertical(lipgloss.Left, rendered...)
		} else {
			cardWidth := max(24, termWidth/2-4)
			cards := buildCards(m.metrics, cardWidth, cpuCores, m.fullCollected)
			cards = append(cards, renderHistoryCard(m.cpuHist, m.memHist, m.metrics, cardWidth))
			cardContent = renderTwoColumns(cards, termWidth)
		}

		// Combine header, mole, and cards with consistent spacing
		parts := []string{header}
		if alertBar != "" {
			parts = append(parts, alertBar)
		}
		if mole != "" {
			parts = append(parts, mole)
		}
		parts = append(parts, cardContent, "", renderFooter(termWidth, m.snakeOpen))
		return lipgloss.JoinVertical(lipgloss.Left, parts...)
	}

	// Every extra core is another card row, and the frame has no scrollback: on
	// a 20-core Mac "all" adds ~18 lines and can overflow a short window.
	// Step the preference back down until the frame fits; the stored
	// preference is untouched, so a taller window gets it back.
	cpuCores := m.cpuCores
	output := renderFrame(cpuCores)
	// With the game open it owns half the screen; the dashboard below is
	// cropped to what is left instead of falling back to "terminal too small".
	if m.snakeOpen && m.height > 0 {
		lines := strings.Split(output, "\n")
		if len(lines) > m.height {
			lines = lines[:m.height]
		}
		return padViewToHeight(strings.Join(lines, "\n"), m.height)
	}
	for m.height > 0 && lipgloss.Height(output) > m.height && cpuCores != cpuCoresCycle[0] {
		cpuCores = smallerCPUCores(cpuCores)
		output = renderFrame(cpuCores)
	}
	if m.height > 0 && lipgloss.Height(output) > m.height {
		output = renderTerminalTooSmall(termWidth, m.height)
	}
	return padViewToHeight(output, m.height)
}

func (m model) collectCmd(mode collectionMode) tea.Cmd {
	return func() tea.Msg {
		return m.collector.collectMode(mode)
	}
}

func tickAfter(delay time.Duration) tea.Cmd {
	return tea.Tick(delay, func(time.Time) tea.Msg { return tickMsg{} })
}

func animTick() tea.Cmd {
	return tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg { return animTickMsg{} })
}

func animTickWithSpeed(cpuUsage float64) tea.Cmd {
	// Higher CPU = faster animation.
	interval := max(300-int(cpuUsage*2.5), 50)
	return tea.Tick(time.Duration(interval)*time.Millisecond, func(time.Time) tea.Msg { return animTickMsg{} })
}

// runJSONMode collects metrics once and outputs as JSON.
func runJSONMode() {
	collector := NewCollector(processWatchOptionsFromFlags())

	data, err := collector.Collect()
	if code := writeJSONSnapshot(os.Stdout, os.Stderr, data, err); code != 0 {
		os.Exit(code)
	}
}

// writeJSONSnapshot follows the watch stream and the dashboard: one failed
// collector is reported on stderr, and the metrics that did succeed are still
// printed and exit 0. A snapshot with no core metrics, or an encoding error, fails.
func writeJSONSnapshot(stdout, stderr io.Writer, data MetricsSnapshot, err error) int {
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "status: falha na coleta: %v\n", err)
	}
	if !hasCoreMetrics(data) {
		if err == nil {
			_, _ = fmt.Fprintln(stderr, "status: falha na coleta: nenhuma métrica coletada")
		}
		return 1
	}

	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(data); err != nil {
		_, _ = fmt.Fprintf(stderr, "erro ao codificar JSON: %v\n", err)
		return 1
	}
	return 0
}

// CollectedAt records the attempt even if every collector failed. Core metrics
// establish a usable sample; idle CPU and an empty process list are valid too.
func hasCoreMetrics(data MetricsSnapshot) bool {
	if data.CPU.LogicalCPU > 0 || data.Memory.Total > 0 || data.ProcessCollectedAt != nil {
		return true
	}
	for _, disk := range data.Disks {
		if disk.Total > 0 {
			return true
		}
	}
	return false
}

// runTUIMode runs the interactive terminal UI.
func runTUIMode() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "erro no status do sistema: %v\n", err)
		os.Exit(1)
	}
}

func parseWatchInterval(raw string) (time.Duration, error) {
	if raw == "" {
		return refreshInterval, nil
	}

	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("--interval inválido %q (use, por exemplo, 1s, 2s): %w", raw, err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("--interval inválido %q (deve ser > 0)", raw)
	}
	return d, nil
}

// usageText is the help every other Mole subcommand prints by hand. The Go flag
// package would otherwise render "Usage of /usr/local/bin/status-go:", naming a
// bundled binary the user never typed, so the text is written out here instead.
const usageText = `Uso: mo status [OPÇÕES]

Monitore a saúde do sistema. Sem opções, abre o painel interativo e passa
para um único snapshot JSON quando a saída não é um terminal.

Opções:
  --json                          Exibe um snapshot de métricas em JSON
  --watch                         Transmite snapshots como JSON delimitado por linhas
  --interval DURATION             Com --watch, intervalo de coleta (padrão 1s)
  --proc-cpu-alerts               Ativa alertas de processos com CPU alta (padrão true)
  --proc-cpu-threshold PERCENT    Alerta acima deste percentual de CPU (padrão 100)
  --proc-cpu-window DURATION      Tempo acima do limite antes de alertar (padrão 5m)
  -h, --help                      Mostra esta ajuda

Exemplos:
  mo status                       Painel interativo
  mo status --json                Um snapshot legível por máquina
  mo status --watch --interval 2s Fluxo NDJSON contínuo
`

// parseArgs applies Mole's CLI conventions to the flag package: help goes to
// stdout and exits 0, and a bad invocation goes to stderr and exits 1 the way
// every bash subcommand does, rather than the flag package's stderr-and-2.
// It returns the exit code and whether main should keep running.
func parseArgs(args []string, stdout, stderr io.Writer) (int, bool) {
	flag.CommandLine.Init("mo status", flag.ContinueOnError)
	// Parse must not print: this function decides which stream each message
	// belongs on, and the default handler writes usage to stderr for both.
	flag.CommandLine.SetOutput(io.Discard)
	flag.CommandLine.Usage = func() {}

	err := flag.CommandLine.Parse(args)
	switch {
	case errors.Is(err, flag.ErrHelp):
		_, _ = fmt.Fprint(stdout, usageText)
		return 0, false
	case err != nil:
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'mo status --help' para ver o modo de uso")
		return 1, false
	}

	if err := validateFlags(); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'mo status --help' para ver o modo de uso")
		return 1, false
	}
	return 0, true
}

func main() {
	if code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr); !keepGoing {
		os.Exit(code)
	}

	if *watchMode {
		interval, err := parseWatchInterval(*watchInterval)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			fmt.Fprintln(os.Stderr, "Use 'mo status --help' para ver o modo de uso")
			os.Exit(1)
		}
		runWatchMode(interval)
		return
	}

	if shouldUseJSONOutput(*jsonOutput, os.Stdout) {
		runJSONMode()
	} else {
		runTUIMode()
	}
}

func activeAlerts(alerts []ProcessAlert) []ProcessAlert {
	var active []ProcessAlert
	for _, alert := range alerts {
		if alert.Status == "active" {
			active = append(active, alert)
		}
	}
	return active
}
