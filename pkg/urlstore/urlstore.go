package urlstore

import (
	ctx "context"
	"time"

	"github.com/FlorinBalint/shortener/pkg/gcputil"
	"github.com/google/gomemcache/memcache"
)

// Client is the interface for URL storage.
type Client interface {
	Close() error
	CreateEntry(ctx ctx.Context, key UrlKey, entry URLEntry) error
	GetEntry(ctx ctx.Context, urlKey UrlKey) (URLEntry, error)
}

// DSClient is a minimal key->JSON datastore client.
// JSON is stored as a single noindex property to avoid indexing limits.
type DSClient struct {
	client *gcputil.DSClient
}

var _ Client = (*DSClient)(nil)

func NewClient(client *gcputil.DSClient) *DSClient {
	return &DSClient{
		client: client,
	}
}

func (c *DSClient) Close() error {
	return c.client.Close()
}

func (c *DSClient) CreateEntry(ctx ctx.Context, key UrlKey, entry URLEntry) error {
	return gcputil.PutNewValue(c.client, ctx, "url_entry", string(key), entry)
}

func (c *DSClient) GetEntry(ctx ctx.Context, urlKey UrlKey) (URLEntry, error) {
	return gcputil.GetValue[URLEntry](c.client, ctx, "url_entry", string(urlKey))
}

func (c *DSClient) WithCacheAside(cache *memcache.Client) *CachedClient {
	return newCachedClient(c, cache)
}

type UrlKey string

type URLEntry struct {
	URLTarget         string    `json:"url_target"`
	CreationTimestamp time.Time `json:"create_timestamp"`
}
