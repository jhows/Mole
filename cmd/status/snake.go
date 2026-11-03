package main

import (
	"fmt"
	"math/rand"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	snakeRows     = 4
	snakeMaxCols  = 20
	snakeMinCols  = 6
	snakeStepTime = 140 * time.Millisecond
)

type snakeTickMsg struct{}

type snakePoint struct{ x, y int }

// snakeGame is a tiny wrap-around snake that lives where the mole used to run.
// Only hitting itself ends the game, so an untouched snake just keeps circling.
type snakeGame struct {
	cols  int
	body  []snakePoint // head first
	dir   snakePoint
	next  snakePoint
	food  snakePoint
	score int
	best  int
	over  bool
}

func newSnakeGame(cols int) *snakeGame {
	g := &snakeGame{}
	g.reset(cols)
	return g
}

func snakeColsFor(termWidth int) int {
	cols := (termWidth - 2) / 2
	return min(max(cols, snakeMinCols), snakeMaxCols)
}

func (g *snakeGame) reset(cols int) {
	g.cols = cols
	g.body = []snakePoint{{3, 1}, {2, 1}, {1, 1}}
	g.dir = snakePoint{1, 0}
	g.next = g.dir
	g.score = 0
	g.over = false
	g.placeFood()
}

func (g *snakeGame) occupied(p snakePoint) bool {
	for _, b := range g.body {
		if b == p {
			return true
		}
	}
	return false
}

func (g *snakeGame) placeFood() {
	free := make([]snakePoint, 0, g.cols*snakeRows)
	for y := 0; y < snakeRows; y++ {
		for x := 0; x < g.cols; x++ {
			if p := (snakePoint{x, y}); !g.occupied(p) {
				free = append(free, p)
			}
		}
	}
	if len(free) == 0 {
		g.over = true
		return
	}
	g.food = free[rand.Intn(len(free))]
}

// ensureCols restarts the board when the terminal width changes the grid size.
func (g *snakeGame) ensureCols(cols int) {
	if cols != g.cols {
		g.reset(cols)
	}
}

func (g *snakeGame) turn(d snakePoint) {
	if d.x == -g.dir.x && d.y == -g.dir.y {
		return
	}
	g.next = d
}

func (g *snakeGame) step() {
	if g.over {
		return
	}
	g.dir = g.next
	head := g.body[0]
	nh := snakePoint{
		x: (head.x + g.dir.x + g.cols) % g.cols,
		y: (head.y + g.dir.y + snakeRows) % snakeRows,
	}
	ate := nh == g.food
	// The tail cell frees up this step unless the snake grows.
	check := g.body
	if !ate {
		check = g.body[:len(g.body)-1]
	}
	for _, b := range check {
		if b == nh {
			g.over = true
			g.best = max(g.best, g.score)
			return
		}
	}
	g.body = append([]snakePoint{nh}, g.body...)
	if ate {
		g.score++
		g.best = max(g.best, g.score)
		g.placeFood()
		return
	}
	g.body = g.body[:len(g.body)-1]
}

func (g *snakeGame) handleKey(key string) bool {
	switch key {
	case "up", "w":
		g.turn(snakePoint{0, -1})
	case "down", "s":
		g.turn(snakePoint{0, 1})
	case "left", "a":
		g.turn(snakePoint{-1, 0})
	case "right", "d":
		g.turn(snakePoint{1, 0})
	case "r", " ", "enter":
		if g.over {
			g.reset(g.cols)
		}
	default:
		return false
	}
	return true
}

func (g *snakeGame) render() string {
	var status string
	if g.over {
		status = dangerStyle.Render(fmt.Sprintf("Fim de jogo! %d pts", g.score)) +
			subtleStyle.Render("  ·  R recomeça")
	} else {
		status = subtleStyle.Render(fmt.Sprintf("Cobrinha %d pts  ·  recorde %d  ·  ←↑↓→ ou WASD  ·  K esconde", g.score, g.best))
	}

	lines := []string{status}
	for y := 0; y < snakeRows; y++ {
		var row strings.Builder
		for x := 0; x < g.cols; x++ {
			p := snakePoint{x, y}
			switch {
			case p == g.body[0]:
				row.WriteString(primaryStyle.Bold(true).Render("██"))
			case g.occupied(p):
				row.WriteString(primaryStyle.Render("▒▒"))
			case p == g.food:
				row.WriteString(warnStyle.Render("● "))
			default:
				row.WriteString(subtleStyle.Render("· "))
			}
		}
		lines = append(lines, row.String())
	}
	return strings.Join(lines, "\n")
}

func snakeTick() tea.Cmd {
	return tea.Tick(snakeStepTime, func(time.Time) tea.Msg { return snakeTickMsg{} })
}
