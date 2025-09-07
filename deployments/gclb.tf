locals {
  // Versioned bucket name aligned with deploy_static_web.sh:
  // shortener-static-<project>-<static_version>-<region>
  static_bucket_name = coalesce(var.static_bucket, "shortener-static-${local.actual_project}-${var.static_version}-${local.gcp_region}")
  static_path_prefix = var.static_version != "" ? "/static/${var.static_version}" : "/static"

  cluster_zones   = length(var.lb_zones) > 0 ? var.lb_zones : [var.location]
  reader_neg_base = "${var.app_name}-reader-neg"
  writer_neg_base = "${var.app_name}-writer-neg"

  reader_neg_pairs = { for z in local.cluster_zones : z => { name = local.reader_neg_base, zone = z } }
  writer_neg_pairs = { for z in local.cluster_zones : z => { name = local.writer_neg_base, zone = z } }
}

# Read live Services to get neg-status (controller-added)
data "kubernetes_service" "reader_live" {
  metadata {
    name      = kubernetes_service.reader_svc.metadata[0].name
    namespace = kubernetes_service.reader_svc.metadata[0].namespace
  }
  depends_on = [kubernetes_service.reader_svc]
}

data "kubernetes_service" "writer_live" {
  metadata {
    name      = kubernetes_service.writer_svc.metadata[0].name
    namespace = kubernetes_service.writer_svc.metadata[0].namespace
  }
  depends_on = [kubernetes_service.writer_svc]
}

# GCS backend (static root)
resource "google_compute_backend_bucket" "static_root" {
  name        = "${var.app_name}-static-bucket"
  bucket_name = local.static_bucket_name
  enable_cdn  = true
}

# Health checks use the serving port from NEGs
resource "google_compute_health_check" "reader" {
  name = "${var.app_name}-reader-hc"
  http_health_check {
    request_path       = "/health"
    port_specification = "USE_SERVING_PORT"
  }
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
}

resource "google_compute_health_check" "writer" {
  name = "${var.app_name}-writer-hc"
  http_health_check {
    request_path       = "/health"
    port_specification = "USE_SERVING_PORT"
  }
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
}

# Look up the NEGs by name/zone from the Service annotation
data "google_compute_network_endpoint_group" "reader" {
  for_each = local.reader_neg_pairs
  name     = each.value.name
  zone     = each.value.zone
}

data "google_compute_network_endpoint_group" "writer" {
  for_each = local.writer_neg_pairs
  name     = each.value.name
  zone     = each.value.zone
}

// Backend services use NEGs by self_link string (no data sources)
resource "google_compute_backend_service" "reader" {
  name                  = "${var.app_name}-reader-bes"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  health_checks         = [google_compute_health_check.reader.id]
  timeout_sec           = 30

  dynamic "backend" {
    for_each = local.reader_neg_pairs
    content {
      balancing_mode = "RATE"
      max_rate_per_endpoint = 100
      group = "projects/${local.actual_project}/zones/${backend.value.zone}/networkEndpointGroups/${backend.value.name}"
    }
  }

  depends_on = [kubernetes_service.reader_svc]
}

resource "google_compute_backend_service" "writer" {
  name                  = "${var.app_name}-writer-bes"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  health_checks         = [google_compute_health_check.writer.id]
  timeout_sec           = 30

  dynamic "backend" {
    for_each = local.writer_neg_pairs
    content {
      balancing_mode = "RATE"
      max_rate_per_endpoint = 100
      group = "projects/${local.actual_project}/zones/${backend.value.zone}/networkEndpointGroups/${backend.value.name}"
    }
  }

  depends_on = [kubernetes_service.writer_svc]
}

# URL map: exact "/" -> bucket, "/write" prefix -> writer, default -> reader
resource "google_compute_url_map" "shortener" {
  name            = "${var.app_name}-urlmap"
  default_service = google_compute_backend_service.reader.self_link

  path_matcher {
    name            = "pm1"
    default_service = google_compute_backend_service.reader.self_link

    # Writer API
    path_rule {
      paths   = ["/write", "/write/*"]
      service = google_compute_backend_service.writer.self_link
    }

    # Versioned static assets
    path_rule {
      paths   = ["${local.static_path_prefix}/*"]
      service = google_compute_backend_bucket.static_root.self_link
    }

    # Root index.html
    path_rule {
      paths   = ["/"]
      service = google_compute_backend_bucket.static_root.self_link
    }
  }

  host_rule {
    hosts        = ["*"]
    path_matcher = "pm1"
  }

  depends_on = [
    google_compute_backend_service.writer,
    google_compute_backend_service.reader,
    google_compute_backend_bucket.static_root,
  ]
}

# Reserve one global static IP (used by HTTPS)
resource "google_compute_global_address" "lb_ip" {
  name = "${var.app_name}-lb-ip"
}

# Managed SSL certificate (domains must point to the IP below)
resource "google_compute_managed_ssl_certificate" "shortener" {
  name = "${var.app_name}-managed-cert"
  managed {
    domains = var.ssl_domains
  }
}

# Use the same URL map as before
resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "${var.app_name}-https-proxy"
  url_map          = google_compute_url_map.shortener.id
  ssl_certificates = [google_compute_managed_ssl_certificate.shortener.id]
}

# HTTPS forwarding rule (443) using the reserved IP
resource "google_compute_global_forwarding_rule" "https_fr" {
  name                  = "${var.app_name}-https-fr"
  ip_address            = google_compute_global_address.lb_ip.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.https_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_protocol           = "TCP"
}
