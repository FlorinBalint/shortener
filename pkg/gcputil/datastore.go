package gcputil

import (
	ctx "context"
	"encoding/json"
	"errors"
	"strings"

	"cloud.google.com/go/datastore"
	"google.golang.org/api/option"
)

// DSClient is a minimal key->JSON datastore client.
// JSON is stored as a single noindex property to avoid indexing limits.
type DSClient struct {
	client    *datastore.Client
	namespace string
}

// NewDSClient creates a client for a project and optional namespace.
// If endpoint is non-empty, it is passed via option.WithEndpoint.
// For local emulators (localhost), auth is disabled automatically.
// For the official API, endpoint may be left empty (default).
func NewDSClient(ctx ctx.Context, projectID, endpoint, namespace string, extraOpts ...option.ClientOption) (*DSClient, error) {
	opts := make([]option.ClientOption, 0, 2+len(extraOpts))
	if endpoint != "" {
		opts = append(opts, option.WithEndpoint(endpoint))
		// Emulator typically runs on localhost; disable auth in that case.
		if strings.Contains(endpoint, "localhost") || strings.HasPrefix(endpoint, "http://") {
			opts = append(opts, option.WithoutAuthentication())
		}
	}
	opts = append(opts, extraOpts...)
	if projectID == "" {
		projectID = datastore.DetectProjectID
	}

	c, err := datastore.NewClient(ctx, projectID, opts...)
	if err != nil {
		return nil, err
	}
	return &DSClient{client: c, namespace: namespace}, nil
}

// Close closes the underlying client.
func (c *DSClient) Close() error {
	return c.client.Close()
}

type jsonBlob struct {
	Raw []byte `datastore:"raw,noindex"`
}

func (c *DSClient) key(kind, name string) *datastore.Key {
	k := datastore.NameKey(kind, name, nil)
	if c.namespace != "" {
		k.Namespace = c.namespace
	}
	return k
}

// PutJSON stores v as JSON under (kind, name).
// v can be any Go value (marshaled to JSON) or []byte (treated as raw JSON).
func (c *DSClient) PutJSON(ctx ctx.Context, kind, name string, v any) error {
	var b []byte
	switch t := v.(type) {
	case []byte:
		b = t
	default:
		j, err := json.Marshal(v)
		if err != nil {
			return err
		}
		b = j
	}
	_, err := c.client.Put(ctx, c.key(kind, name), &jsonBlob{Raw: b})
	return err
}

// GetJSON fetches JSON stored at (kind, name).
// If out is non-nil, it attempts json.Unmarshal into out.
// It always returns the raw JSON bytes (even if unmarshal fails).
func (c *DSClient) GetJSON(ctx ctx.Context, kind, name string, out any) ([]byte, error) {
	var e jsonBlob
	if err := c.client.Get(ctx, c.key(kind, name), &e); err != nil {
		return nil, err
	}
	if out != nil {
		_ = json.Unmarshal(e.Raw, out) // caller can inspect error if needed
	}
	return e.Raw, nil
}

// PutValue stores a typed value as JSON (T -> JSON).
func PutValue[T any](client *DSClient, ctx ctx.Context, kind, name string, v T) error {
	j, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = client.client.Put(ctx, client.key(kind, name), &jsonBlob{Raw: j})
	return err
}

// GetValue loads JSON and decodes it into the requested type (JSON -> T).
// Returns zero T and error if entity is missing or JSON is invalid.
func GetValue[T any](client *DSClient, ctx ctx.Context, kind, name string) (T, error) {
	var out T
	var e jsonBlob
	if err := client.client.Get(ctx, client.key(kind, name), &e); err != nil {
		return out, err
	}
	if len(e.Raw) == 0 {
		return out, errors.New("empty JSON payload")
	}
	if err := json.Unmarshal(e.Raw, &out); err != nil {
		return out, err
	}
	return out, nil
}

// Delete removes the entity at (kind, name).
func (c *DSClient) Delete(ctx ctx.Context, kind, name string) error {
	return c.client.Delete(ctx, c.key(kind, name))
}
