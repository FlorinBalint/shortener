locals {
  // Derive region from zone without regex
  parts          = split("-", var.location)
  derived_region = length(local.parts) == 3 ? join("-", slice(local.parts, 0, 2)) : var.location
  reg_region     = var.registry_region != "" ? var.registry_region : local.derived_region

  // Path where we write kubeconfig for this cluster
  kubeconfig_path = "${path.module}/.kubeconfig"
}

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.location

  // Let us manage the node pool below
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  network         = "default"
  subnetwork      = "default"

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {}
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-pool"
  location   = var.location
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = var.node_disk_type // ensure non-SSD to avoid SSD_TOTAL_GB
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    metadata = {
      disable-legacy-endpoints = "true"
    }
    labels = {
      app = var.app_name
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Write kubeconfig for this cluster before any Kubernetes resources
resource "null_resource" "get_kubeconfig" {
  triggers = {
    cluster  = google_container_cluster.primary.name
    location = google_container_cluster.primary.location
    project  = var.project_id
  }

  provisioner "local-exec" {
    command = "KUBECONFIG='${local.kubeconfig_path}' gcloud container clusters get-credentials ${google_container_cluster.primary.name} --location ${google_container_cluster.primary.location} --project ${var.project_id}"
  }
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "location" {
  value = google_container_cluster.primary.location
}

output "kubeconfig_path" {
  value = local.kubeconfig_path
}
