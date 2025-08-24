package gcputil

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// ...existing code...

// Additional errors for zone discovery.
var (
	ErrGCPZoneNotFound        = errors.New("gcp zone not found")
	ErrGCPMetadataUnavailable = errors.New("gcp metadata server unavailable")
)

// GCPZone returns the GCP zone for the current pod's node.
// It checks env overrides (GCP_ZONE, ZONE), then queries the metadata server:
//
//	http://metadata.google.internal/computeMetadata/v1/instance/zone
//
// Requires header: Metadata-Flavor: Google
func GCPZone(ctx context.Context) (string, error) {
	// Env overrides (useful in tests or non-GCP environments)
	if z := strings.TrimSpace(os.Getenv("GCP_ZONE")); z != "" {
		return z, nil
	}
	if z := strings.TrimSpace(os.Getenv("ZONE")); z != "" {
		return z, nil
	}

	// Metadata host override per GCE conventions
	base := "http://metadata.google.internal"
	if h := strings.TrimSpace(os.Getenv("GCE_METADATA_HOST")); h != "" {
		if strings.HasPrefix(h, "http://") || strings.HasPrefix(h, "https://") {
			base = h
		} else {
			base = "http://" + h
		}
	}

	url := base + "/computeMetadata/v1/instance/zone"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", ErrGCPMetadataUnavailable
	}
	req.Header.Set("Metadata-Flavor", "Google")

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", ErrGCPMetadataUnavailable
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", ErrGCPMetadataUnavailable
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", ErrGCPMetadataUnavailable
	}
	s := strings.TrimSpace(string(body))
	if s == "" {
		return "", ErrGCPZoneNotFound
	}

	// Response format: projects/<num>/zones/<zone>
	if i := strings.LastIndexByte(s, '/'); i >= 0 && i+1 < len(s) {
		s = s[i+1:]
	}
	if s == "" {
		return "", ErrGCPZoneNotFound
	}
	return s, nil
}
