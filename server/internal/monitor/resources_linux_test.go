//go:build linux

package monitor

import "testing"

func TestLinuxRuntimeResourceSampling(t *testing.T) {
	reading := readResources()
	if !reading.cpuAvailable || reading.cpuSeconds < 0 {
		t.Fatal("process CPU time unavailable on Linux")
	}
	if reading.resources.RSSBytes == nil || *reading.resources.RSSBytes == 0 {
		t.Fatal("Linux process RSS unavailable")
	}
	if reading.resources.SystemMemoryTotal == nil || *reading.resources.SystemMemoryTotal == 0 {
		t.Fatal("Linux system memory unavailable")
	}
	if reading.cpuTotal == 0 {
		t.Fatal("Linux CPU counters unavailable")
	}
	s := console(t)
	s.sample()
	if s.resources.ProcessCPUPercent == nil || *s.resources.ProcessCPUPercent < 0 {
		t.Fatal("CPU delta sampling missing")
	}
	if len(s.history) != 2 || s.history[1].RSSBytes == nil {
		t.Fatal("resource history missing")
	}
}
