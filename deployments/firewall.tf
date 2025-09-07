// Derive the network name from the cluster's network (handles selfLink or plain name)
locals {
  cluster_network_link = google_container_cluster.primary.network
  cluster_network_name = local.cluster_network_link
}

resource "google_compute_firewall" "allow_hc_to_nodeports" {
  name = "${var.app_name}-allow-hc"
  # project inherits from provider if you prefer
  # project = local.actual_project
  network = local.cluster_network_name

  direction = "INGRESS"
  priority  = 1000

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]

  allow {
    protocol = "tcp"
    ports = [
      tostring(var.reader_port),
      tostring(var.writer_port)
    ]
  }
}