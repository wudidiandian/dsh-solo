//go:build linux

package monitor

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

func readUintFile(path string) *uint64 {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	value, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return nil
	}
	return &value
}
func readPlatform() platformReading {
	var r platformReading
	var usage syscall.Rusage
	if syscall.Getrusage(syscall.RUSAGE_SELF, &usage) == nil {
		r.cpuSeconds = float64(usage.Utime.Sec+usage.Stime.Sec) + float64(usage.Utime.Usec+usage.Stime.Usec)/1e6
		r.cpuAvailable = true
	}
	if data, err := os.ReadFile("/proc/self/statm"); err == nil {
		parts := strings.Fields(string(data))
		if len(parts) > 1 {
			if n, e := strconv.ParseUint(parts[1], 10, 64); e == nil {
				v := n * uint64(os.Getpagesize())
				r.resources.RSSBytes = &v
			}
		}
	}
	if data, err := os.ReadFile("/proc/stat"); err == nil {
		line := strings.SplitN(string(data), "\n", 2)[0]
		parts := strings.Fields(line)
		// guest fields are already included in user/nice and must not be counted twice.
		for i := 1; i < len(parts) && i <= 8; i++ {
			v, _ := strconv.ParseUint(parts[i], 10, 64)
			r.cpuTotal += v
			if i == 4 || i == 5 {
				r.cpuIdle += v
			}
		}
	}
	if data, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			p := strings.Fields(line)
			if len(p) < 2 {
				continue
			}
			v, e := strconv.ParseUint(p[1], 10, 64)
			if e != nil {
				continue
			}
			v *= 1024
			switch p[0] {
			case "MemTotal:":
				r.resources.SystemMemoryTotal = &v
			case "MemAvailable:":
				r.resources.SystemMemoryAvailable = &v
			}
		}
	}
	if data, err := os.ReadFile("/proc/net/dev"); err == nil {
		var received, sent uint64
		for _, line := range strings.Split(string(data), "\n") {
			name, rest, ok := strings.Cut(line, ":")
			if !ok || strings.TrimSpace(name) == "lo" {
				continue
			}
			p := strings.Fields(rest)
			if len(p) < 9 {
				continue
			}
			rx, _ := strconv.ParseUint(p[0], 10, 64)
			tx, _ := strconv.ParseUint(p[8], 10, 64)
			received += rx
			sent += tx
		}
		r.resources.SystemNetworkIn = &received
		r.resources.SystemNetworkOut = &sent
	}
	r.resources.ContainerMemoryUsage = readUintFile("/sys/fs/cgroup/memory.current")
	r.resources.ContainerMemoryLimit = readUintFile("/sys/fs/cgroup/memory.max")
	if r.resources.ContainerMemoryUsage == nil {
		r.resources.ContainerMemoryUsage = readUintFile("/sys/fs/cgroup/memory/memory.usage_in_bytes")
		r.resources.ContainerMemoryLimit = readUintFile("/sys/fs/cgroup/memory/memory.limit_in_bytes")
	}
	if data, err := os.ReadFile("/sys/fs/cgroup/cpu.max"); err == nil {
		p := strings.Fields(string(data))
		if len(p) == 2 {
			quota, e := strconv.ParseFloat(p[0], 64)
			period, e2 := strconv.ParseFloat(p[1], 64)
			if e == nil && e2 == nil && quota > 0 && period > 0 {
				v := quota / period
				r.resources.CPUQuotaCores = &v
			}
		}
	}
	if r.resources.CPUQuotaCores == nil {
		quota := readUintFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
		period := readUintFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
		if quota != nil && period != nil && *period > 0 && *quota > 0 {
			v := float64(*quota) / float64(*period)
			r.resources.CPUQuotaCores = &v
		}
	}
	return r
}
