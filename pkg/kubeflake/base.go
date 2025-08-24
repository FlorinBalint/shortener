package kubeflake

import "bytes"

const base62Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

var base62Bytes = []byte(base62Chars)

type BaseEncoder interface {
	Encode(n uint64) string
	Decode(s string) (uint64, error)
}

type Base62Encoder struct{}

// EncodeBase62 converts an uint64 to a base62-encoded string.
func (Base62Encoder) Encode(n uint64) string {
	if n == 0 {
		return "0"
	}
	result := make([]byte, 0)
	for n > 0 {
		remainder := n % 62
		result = append([]byte{base62Chars[remainder]}, result...)
		n = n / 62
	}
	return string(result)
}

// DecodeBase62 converts a base62-encoded string to an uint64
func (Base62Encoder) Decode(s string) (uint64, error) {
	var result uint64
	for i := 0; i < len(s); i++ {
		char := s[i]
		index := bytes.IndexByte(base62Bytes, char)
		if index == -1 {
			return 0, ErrInvalidBase
		}
		result = result*62 + uint64(index)
	}
	return result, nil
}
