package gcputil

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
)

// StatefulSetPod provides utilities to identify a pod running in a Kubernetes StatefulSet.
// It derives the pod "ID" as the StatefulSet ordinal (0-based integer) from the pod name.
// In StatefulSets, pod names are formatted as: <statefulset-name>-<ordinal>, e.g. "web-2".
type StatefulSetPod struct {
	// Delimiter separates the base name from the ordinal. Defaults to "-" when empty.
	Delimiter string

	// getenv allows overriding env lookups (useful for tests).
	getenv func(string) string
	// getHostname allows overriding hostname lookup (useful for tests).
	getHostname func() (string, error)
}

// Errors returned by StatefulSetPod.
var (
	ErrPodNameNotFound = errors.New("statefulset pod name not found from environment or hostname")
	ErrZoneNotFound    = errors.New("statefulset pod zone not found from metadata server")
	ErrOrdinalNotFound = errors.New("ordinal suffix not found or not numeric in pod name")
)

// NewStatefulSetPod creates a new provider that reads the pod name from:
// 1) POD_NAME environment variable (if set via Downward API)
// 2) HOSTNAME environment variable (Kubernetes sets this by default)
// 3) os.Hostname() as a final fallback.
//
// The ordinal is parsed from the last Delimiter-separated segment of the name.
func NewStatefulSetPod() *StatefulSetPod {
	return &StatefulSetPod{
		Delimiter:   "-",
		getenv:      os.Getenv,
		getHostname: os.Hostname,
	}
}

// PodName returns the current pod's name discovered from environment/hostname sources.
func (p *StatefulSetPod) PodName() (string, error) {
	if p.getenv == nil {
		p.getenv = os.Getenv
	}
	if p.getHostname == nil {
		p.getHostname = os.Hostname
	}

	// Preferred: Downward API provided POD_NAME
	if name := p.getenv("POD_NAME"); name != "" {
		return name, nil
	}
	// Kubernetes typically sets HOSTNAME to the pod name
	if name := p.getenv("HOSTNAME"); name != "" {
		return name, nil
	}
	// Fallback to system hostname
	if hn, err := p.getHostname(); err == nil && hn != "" {
		return hn, nil
	}
	return "", ErrPodNameNotFound
}

// PodID returns the StatefulSet ordinal (0-based) parsed from the pod name.
// For a pod name like "web-2", PodID() returns 2.
func (p *StatefulSetPod) PodID() (int, error) {
	name, err := p.PodName()
	if err != nil {
		return 0, err
	}
	d := p.Delimiter
	if d == "" {
		d = "-"
	}

	// Find last delimiter and parse the numeric suffix.
	idx := strings.LastIndex(name, d)
	if idx < 0 || idx == len(name)-1 {
		return 0, ErrOrdinalNotFound
	}
	suffix := name[idx+1:]
	n, convErr := strconv.Atoi(suffix)
	if convErr != nil {
		return 0, ErrOrdinalNotFound
	}
	return n, nil
}

// ClusterID returns the GCP cluster ID for the pod.
func (p *StatefulSetPod) ClusterID() (int, error) {
	podZone, err := GCPZone(context.Background())
	if err != nil {
		return 0, err
	}
	if len(podZone) == 0 {
		return 0, ErrZoneNotFound
	}
	zoneId, ok := ZoneIndex(podZone)
	if !ok {
		return 0, ErrZoneNotFound
	}
	return zoneId, nil
}
