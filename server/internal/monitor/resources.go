package monitor

import "runtime"

type Resources struct {
	Platform              string   `json:"platform"`
	LogicalCPUs           int      `json:"logicalCpus"`
	Goroutines            int      `json:"goroutines"`
	HeapBytes             uint64   `json:"heapBytes"`
	GoSystemBytes         uint64   `json:"goSystemBytes"`
	RSSBytes              *uint64  `json:"rssBytes"`
	ProcessCPUPercent     *float64 `json:"processCpuPercent"`
	SystemCPUPercent      *float64 `json:"systemCpuPercent"`
	SystemMemoryTotal     *uint64  `json:"systemMemoryTotal"`
	SystemMemoryAvailable *uint64  `json:"systemMemoryAvailable"`
	SystemNetworkIn       *uint64  `json:"systemNetworkIn"`
	SystemNetworkOut      *uint64  `json:"systemNetworkOut"`
	ContainerMemoryUsage  *uint64  `json:"containerMemoryUsage"`
	ContainerMemoryLimit  *uint64  `json:"containerMemoryLimit"`
	CPUQuotaCores         *float64 `json:"cpuQuotaCores"`
}
type platformReading struct {
	resources         Resources
	cpuSeconds        float64
	cpuAvailable      bool
	cpuTotal, cpuIdle uint64
}

func readResources() platformReading {
	r := readPlatform()
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	r.resources.Platform = runtime.GOOS
	r.resources.LogicalCPUs = runtime.NumCPU()
	r.resources.Goroutines = runtime.NumGoroutine()
	r.resources.HeapBytes = memory.HeapAlloc
	r.resources.GoSystemBytes = memory.Sys
	return r
}
