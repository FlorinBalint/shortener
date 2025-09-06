package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"cloud.google.com/go/datastore"

	"github.com/FlorinBalint/shortener/pkg/gcputil"
	"github.com/FlorinBalint/shortener/pkg/urlstore"
)

type ReaderConfig struct {
	ProjectID   string
	DSNamespace string
	DSEndpoint  string
	BindAddr    string
}

func getenvDefault(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// Load config from environment variables, with defaults.
func loadConfigFromEnv() ReaderConfig {
	return ReaderConfig{
		ProjectID:   getenvDefault("GCP_PROJECT", ""),
		DSNamespace: getenvDefault("DS_NAMESPACE", ""),
		DSEndpoint:  getenvDefault("DS_ENDPOINT", ""),
		BindAddr:    getenvDefault("BIND_ADDR", ":8080"), // reader defaults to 8080
	}
}

// Request handler with its dependencies.
type ReaderHandler struct {
	store *urlstore.Client

	// cleanup for dependencies (store, datastore client)
	closeFn func() error
}

// Construct the handler with dependencies (Datastore client, store).
func newReaderHandler(ctx context.Context, cfg ReaderConfig) (*ReaderHandler, error) {
	dsClient, err := gcputil.NewDSClient(ctx, cfg.ProjectID, cfg.DSEndpoint, cfg.DSNamespace)
	if err != nil {
		return nil, fmt.Errorf("datastore: %w", err)
	}
	store := urlstore.NewClient(dsClient, cfg.DSNamespace)

	h := &ReaderHandler{
		store: store,
	}
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
func (h *ReaderHandler) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// Implement http.Handler: route to named handlers and path-based keys.
func (h *ReaderHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/health" && r.Method == http.MethodGet:
		h.handleHealth(w, r)
	default:
		// Support path-based keys: GET /{key}
		if r.Method == http.MethodGet {
			if key := extractKeyFromPath(r.URL.Path); key != "" {
				h.redirectByKey(w, r, key)
				return
			}
		}
		http.NotFound(w, r)
	}
}

func extractKeyFromPath(p string) string {
	trim := strings.Trim(p, "/")
	if trim == "" || trim == "health" {
		return ""
	}
	// first segment is the key
	parts := strings.SplitN(trim, "/", 2)
	return parts[0]
}

func (h *ReaderHandler) redirectByKey(w http.ResponseWriter, r *http.Request, key string) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	entry, err := h.store.GetEntry(ctx, urlstore.UrlKey(key))
	if errors.Is(err, datastore.ErrNoSuchEntity) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("Error reading entry for key %q: %v", key, err)
		http.Error(w, "failed to read entry", http.StatusInternalServerError)
		return
	}

	http.Redirect(w, r, entry.URLTarget, http.StatusFound) // 302
}

// Close releases handler resources (store, datastore client).
func (h *ReaderHandler) Close() error {
	if h.closeFn != nil {
		return h.closeFn()
	}
	return nil
}

func main() {
	ctx := context.Background()
	cfg := loadConfigFromEnv()

	handler, err := newReaderHandler(ctx, cfg)
	if err != nil {
		fmt.Println("Error creating reader handler:", err)
		return
	}
	defer func() {
		if err := handler.Close(); err != nil {
			fmt.Println("Error during reader cleanup:", err)
		}
	}()

	// Register handler on default mux.
	http.Handle("/", handler)

	if err := http.ListenAndServe(cfg.BindAddr, nil); err != nil && err != http.ErrServerClosed {
		fmt.Println("Error starting server:", err)
	}
}
