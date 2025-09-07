// Resolve region from zonal var.location (e.g., us-central1-a -> us-central1)
locals {
  gcp_region = join("-", slice(split("-", var.location), 0, 2))
}

data "google_memcache_instance" "url_cache" {
  // google-beta provider is required for memorystore memcache data source
  provider = google-beta

  project = local.actual_project
  region  = local.gcp_region
  name    = var.memcache_instance_id
}

resource "kubernetes_config_map" "memcache_discovery" {
  metadata {
    name      = "${var.app_name}-memcache"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  data = {
    MEMCACHE_DISCOVERY_ENDPOINT = data.google_memcache_instance.url_cache.discovery_endpoint
  }
}
