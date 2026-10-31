//go:build !linux

package monitor

// Go heap and runtime statistics remain available on all platforms.
// Host/process OS metrics are explicitly unavailable rather than reported as zero.
func readPlatform() platformReading { return platformReading{} }
