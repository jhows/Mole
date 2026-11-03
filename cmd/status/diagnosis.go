package main

import (
	"fmt"
	"strings"
)

func statusDiagnosisLine(m MetricsSnapshot) string {
	for _, disk := range m.Disks {
		if disk.SmartStatus == smartStatusFailing {
			return "SMART falhando, faça backup agora"
		}
	}
	if m.CPU.Usage > cpuHighThreshold {
		if processSnapshotFresh(m.ProcessStale) {
			if proc, ok := leadingCPUProcess(m.TopProcesses, 50); ok {
				return fmt.Sprintf("%s CPU alta", shorten(proc.Name, 18))
			}
		}
		return "Carga de CPU alta"
	}
	if m.Memory.Pressure == "warn" || m.Memory.Pressure == "critical" || m.Memory.UsedPercent > memHighThreshold {
		if processSnapshotFresh(m.ProcessStale) {
			if proc, ok := leadingMemoryProcess(m.TopProcesses); ok && proc.Memory > 0 {
				return fmt.Sprintf("%s pressão de memória", shorten(proc.Name, 18))
			}
		}
		return "Pressão de memória alta"
	}
	if disk, ok := rootDisk(m.Disks); ok && diskIsCritical(disk) {
		free := uint64(0)
		if disk.Total > disk.Used {
			free = disk.Total - disk.Used
		}
		return fmt.Sprintf("Pouco disco, %s livres", humanBytesShort(free))
	}
	for _, battery := range m.Batteries {
		if battery.Capacity > 0 && battery.Capacity < batteryCapWarn {
			return "Saúde da bateria baixa"
		}
		if battery.CycleCount > batteryCycleWarn {
			return "Ciclos de bateria altos"
		}
	}
	if m.Thermal.CPUTemp > thermalNormalThreshold {
		return "Temperatura da CPU alta"
	}
	if totalIO := m.DiskIO.ReadRate + m.DiskIO.WriteRate; totalIO > ioHighThreshold {
		return "Disco (E/S) ocupado"
	}
	if strings.Contains(m.HealthScoreMsg, ":") {
		return m.HealthScoreMsg
	}
	return "Tudo certo"
}

func leadingCPUProcess(procs []ProcessInfo, threshold float64) (ProcessInfo, bool) {
	var best ProcessInfo
	for i, proc := range procs {
		if i == 0 || proc.CPU > best.CPU {
			best = proc
		}
	}
	if best.CPU < threshold {
		return ProcessInfo{}, false
	}
	return best, true
}

func leadingMemoryProcess(procs []ProcessInfo) (ProcessInfo, bool) {
	var best ProcessInfo
	for i, proc := range procs {
		if i == 0 || proc.Memory > best.Memory {
			best = proc
		}
	}
	return best, len(procs) > 0
}

func rootDisk(disks []DiskStatus) (DiskStatus, bool) {
	for _, disk := range disks {
		if disk.Mount == "/" {
			return disk, true
		}
	}
	if len(disks) == 0 {
		return DiskStatus{}, false
	}
	return disks[0], true
}
