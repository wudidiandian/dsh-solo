package proto

import (
	"errors"
	"time"
)

var (
	// ErrVersionUnsupported 对端使用了更高协议版本
	ErrVersionUnsupported = errors.New("dsh: protocol version unsupported")
	// ErrMissingToken 握手缺少 deviceToken
	ErrMissingToken = errors.New("dsh: missing deviceToken")
)

func timeNowUnixMilli() int64 {
	return time.Now().UnixMilli()
}
