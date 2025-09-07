// Derive the authorized network from the GKE cluster
data "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.location
  # project comes from the provider
}

locals {
  # Cluster network may be name or full URI; normalize to projects/.../global/networks/...
  cluster_net_link = data.google_container_cluster.primary.network
}

resource "google_memcache_instance" "url_cache" {
  name               = var.memcache_instance_id
  region             = local.gcp_region
  authorized_network = local.cluster_net_link
  memcache_version   = "MEMCACHE_1_6_15"

  node_count = var.memcache_node_count

  node_config {
    cpu_count      = var.memcache_node_cpu
    memory_size_mb = var.memcache_node_memory_mb
  }

  # Optional labels
  labels = {
    app = var.app_name
  }
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
    MEMCACHE_DISCOVERY_ENDPOINT = google_memcache_instance.url_cache.discovery_endpoint
  }
}
