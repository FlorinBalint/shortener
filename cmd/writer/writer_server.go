package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"cloud.google.com/go/datastore"

	"github.com/FlorinBalint/shortener/pkg/gcputil"
	"github.com/FlorinBalint/shortener/pkg/urlstore"
)

type writeRequest struct {
	URLKey    string `json:"url_key,omitempty"`
	URLTarget string `json:"url_target"`
}

type writeResponse struct {
	URLKey    string `json:"url_key"`
	URLTarget string `json:"url_target"`
}

type WriterConfig struct {
	ProjectID   string
	DSNamespace string
	DSEndpoint  string
	KeygenBase  string
	BindAddr    string
}

func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// Load config from environment variables, with defaults.
func loadConfigFromEnv() WriterConfig {
	return WriterConfig{
		ProjectID:   getenvDefault("GCP_PROJECT", ""),
		DSNamespace: getenvDefault("DS_NAMESPACE", ""),
		DSEndpoint:  getenvDefault("DS_ENDPOINT", ""),
		KeygenBase:  getenvDefault("KEYGEN_BASE_URL", "http://shortener-keygen-headless.shortener.svc.cluster.local:8083"),
		BindAddr:    getenvDefault("BIND_ADDR", ":8081"),
	}
}

// Request handler with its dependencies.
type WriterHandler struct {
	store      urlstore.Client
	keygenBase string
	httpClient *http.Client

	// cleanup for dependencies (store, datastore client)
	closeFn func() error
}

// Construct the handler with dependencies (Datastore client, store, HTTP client).
func newWriterHandler(ctx context.Context, cfg WriterConfig) (*WriterHandler, error) {
	dsClient, err := gcputil.NewDSClient(ctx, cfg.ProjectID, cfg.DSEndpoint, cfg.DSNamespace)
	if err != nil {
		return nil, fmt.Errorf("datastore: %w", err)
	}
	store := urlstore.NewClient(dsClient)

	h := &WriterHandler{
		store:      store,
		keygenBase: cfg.KeygenBase,
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}

	// Compose a closer that shuts down store then the DS client.
	h.closeFn = func() error {
		var cerr error
		if h.store != nil {
			if err := h.store.Close(); err != nil {
				cerr = errors.Join(cerr, err)
			}
		}
		if err := dsClient.Close(); err != nil {
			cerr = errors.Join(cerr, err)
		}
		return cerr
	}

	return h, nil
}

// Named handler for /health
func (h *WriterHandler) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// Named handler for /write/v1
func (h *WriterHandler) handleWrite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req writeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if req.URLTarget == "" {
		http.Error(w, "url_target is required", http.StatusBadRequest)
		return
	}

	key := req.URLKey
	if key == "" {
		gen, err := h.generateNewKey(r.Context())
		if err != nil {
			http.Error(w, "failed to generate key", http.StatusBadGateway)
			return
		}
		key = gen
	}

	// added: normalize and validate alias (allows slashes, blocks static/*)
	key = normalizeAlias(key)
	if err := validateAliasPath(key); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// If a custom key is provided, fail if it already exists.
	if req.URLKey != "" {
		_, err := h.store.GetEntry(r.Context(), urlstore.UrlKey(key))
		if err == nil {
			http.Error(w, "url_key already exists", http.StatusConflict)
			return
		}
		if !errors.Is(err, datastore.ErrNoSuchEntity) {
			http.Error(w, "failed checking existing key", http.StatusInternalServerError)
			return
		}
	}

	entry := urlstore.URLEntry{
		URLTarget:         req.URLTarget,
		CreationTimestamp: time.Now().UTC(),
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := h.store.CreateEntry(ctx, urlstore.UrlKey(key), entry); err != nil {
		http.Error(w, "failed to store entry", http.StatusInternalServerError)
		return
	}

	resp := writeResponse{URLKey: key, URLTarget: req.URLTarget}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// Implement http.Handler: route to named handlers.
func (h *WriterHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/health" && r.Method == http.MethodGet:
		h.handleHealth(w, r)
	case r.URL.Path == "/write/v1":
		h.handleWrite(w, r)
	default:
		http.NotFound(w, r)
	}
}

// Helper used by handleWrite
func (h *WriterHandler) generateNewKey(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, h.keygenBase+"/generate/v1", nil)
	if err != nil {
		return "", err
	}
	resp, err := h.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return "", fmt.Errorf("keygen status %d", resp.StatusCode)
	}

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	return string(bytes.TrimSpace(b)), nil
}

// Close releases handler resources (store, datastore client).
func (h *WriterHandler) Close() error {
	if h.closeFn != nil {
		return h.closeFn()
	}
	return nil
}

// added: alias normalization + validation
var (
	// Allow path-like slugs: letters, digits, underscore, dash, and slash. 1..128 chars.
	aliasPathRe = regexp.MustCompile(`^[A-Za-z0-9/_-]{1,128}$`)

	// Reserved exact aliases (case-insensitive)
	reservedExact = map[string]struct{}{
		"health":      {},
		"write":       {},
		"index.html":  {},
		"favicon.ico": {},
		"robots.txt":  {},
		"sitemap.xml": {},
	}

	// Reserved prefixes (case-insensitive); blocks "static/*"
	reservedPrefixes = []string{
		"write/",
		"health/",
		"static/",
		".well-known/",
	}
)

func normalizeAlias(k string) string {
	k = strings.TrimSpace(k)
	// Accept clients sending "/foo/bar" by stripping a single leading slash.
	k = strings.TrimPrefix(k, "/")
	return k
}

func validateAliasPath(k string) error {
	if k == "" {
		return fmt.Errorf("url_key cannot be empty")
	}
	lk := strings.ToLower(k)

	// Reserved exact matches
	if _, ok := reservedExact[lk]; ok {
		return fmt.Errorf("url_key is reserved")
	}
	// Reserved prefixes (e.g., static/...)
	for _, p := range reservedPrefixes {
		if strings.HasPrefix(lk, p) {
			return fmt.Errorf("url_key is reserved")
		}
	}

	// Disallow path traversal segments
	if strings.Contains(k, "/./") || strings.Contains(k, "/../") || strings.HasPrefix(k, "../") || strings.HasSuffix(k, "/..") {
		return fmt.Errorf("url_key contains invalid path segments")
	}

	// Only allow safe characters
	if !aliasPathRe.MatchString(k) {
		return fmt.Errorf("url_key must match %s", aliasPathRe.String())
	}

	return nil
}

func main() {
	ctx := context.Background()
	cfg := loadConfigFromEnv()

	handler, err := newWriterHandler(ctx, cfg)
	if err != nil {
		fmt.Println("Error creating writer handler:", err)
		return
	}
	// Ensure connections are closed on process exit.
	defer func() {
		if err := handler.Close(); err != nil {
			fmt.Println("Error during writer cleanup:", err)
		}
	}()

	// Register handler on default mux, like keygen.
	http.Handle("/", handler)

	if err := http.ListenAndServe(cfg.BindAddr, nil); err != nil && err != http.ErrServerClosed {
		fmt.Println("Error starting server:", err)
	}
}
