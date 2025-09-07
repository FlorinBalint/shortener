package urlstore

import (
	"context"
	"log"

	"github.com/google/gomemcache/memcache"
)

type CachedClient struct {
	underlying Client
	cache      *memcache.Client
}

var _ Client = (*CachedClient)(nil)

// Close implements Client.
func (c *CachedClient) Close() error {
	c.cache.StopPolling()
	return c.underlying.Close()
}

// CreateEntry implements Client.
func (c *CachedClient) CreateEntry(ctx context.Context, key UrlKey, entry URLEntry) error {
	err := c.underlying.CreateEntry(ctx, key, entry)
	if err != nil {
		return err
	}
	err = c.cache.Set(&memcache.Item{
		Key:   string(key),
		Value: []byte(entry.URLTarget),
	})
	if err != nil {
		// cache set failed, but we have the value, so just log and continue
		log.Printf("memcache set failed: %v", err) // --- IGNORE ---
	}
	return nil
}

// GetEntry implements Client.
func (c *CachedClient) GetEntry(ctx context.Context, urlKey UrlKey) (URLEntry, error) {
	item, err := c.cache.Get(string(urlKey))
	if err == nil {
		return URLEntry{URLTarget: string(item.Value)}, nil
	}
	if err == memcache.ErrCacheMiss {
		entry, err := c.underlying.GetEntry(ctx, urlKey)
		if err != nil {
			return URLEntry{}, err
		}
		err = c.cache.Set(&memcache.Item{
			Key:   string(urlKey),
			Value: []byte(entry.URLTarget),
		})
		if err != nil {
			// cache set failed, but we have the value, so just log and continue
			log.Printf("memcache set failed: %v", err) // --- IGNORE ---
		}
		return entry, nil
	} else {
		return URLEntry{}, err
	}
}

func newCachedClient(underlying Client, cache *memcache.Client) *CachedClient {
	return &CachedClient{
		underlying: underlying,
		cache:      cache,
	}
}
