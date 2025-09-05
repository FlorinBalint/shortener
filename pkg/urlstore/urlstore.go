package urlstore

import (
	ctx "context"
	"time"

	"github.com/FlorinBalint/shortener/pkg/gcputil"
)

// DSClient is a minimal key->JSON datastore client.
// JSON is stored as a single noindex property to avoid indexing limits.
type Client struct {
	client    *gcputil.DSClient
	namespace string
}

func NewClient(client *gcputil.DSClient, namespace string) *Client {
	return &Client{
		client:    client,
		namespace: namespace,
	}
}

func (c *Client) Close() error {
	return c.client.Close()
}

func (c *Client) CreateEntry(ctx ctx.Context, key UrlKey, entry URLEntry) error {
	return gcputil.PutNewValue(c.client, ctx, "url_entry", string(key), entry)
}

func (c *Client) GetEntry(ctx ctx.Context, urlKey UrlKey) (URLEntry, error) {
	return gcputil.GetValue[URLEntry](c.client, ctx, "url_entry", string(urlKey))
}

type UrlKey string

type URLEntry struct {
	URLTarget         string    `json:"url_target"`
	CreationTimestamp time.Time `json:"create_timestamp"`
}
