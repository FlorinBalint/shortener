# Detect from ADC and gcloud config (fallback)
data "google_client_config" "default" {}

data "external" "gcloud_project" {
  program = [
    "bash", "-lc",
    "p=$(gcloud config get-value project 2>/dev/null || true); printf '{\"project\":\"%s\"}\n' \"$p\""
  ]
}

locals {
  # Derive region from zone without regex
  parts          = split("-", var.location)
  derived_region = length(local.parts) == 3 ? join("-", slice(local.parts, 0, 2)) : var.location
  reg_region     = var.registry_region != "" ? var.registry_region : local.derived_region

  # Kubeconfig for this module
  kubeconfig_path = "${path.module}/.kubeconfig"

  # Auto-detected project (TF var -> gcloud config -> provider client_config)
  actual_project = coalesce(
    var.project_id,
    try(data.external.gcloud_project.result.project, ""),
    try(data.google_client_config.default.project, "")
  )
}

resource "google_container_cluster" "primary" {
  project  = local.actual_project
  name     = var.cluster_name
  location = var.location

  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  network         = "default"
  subnetwork      = "default"

  release_channel {
    channel = "STABLE"
  }

  workload_identity_config {
    workload_pool = "${local.actual_project}.svc.id.goog"
  }

  ip_allocation_policy {}

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(local.actual_project) > 0
      error_message = "No GCP project detected."
    }
  }
}

resource "google_container_node_pool" "primary_nodes" {
  project    = local.actual_project
  name       = "${var.cluster_name}-pool"
  location   = var.location
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = var.node_disk_size_gb
    disk_type    = var.node_disk_type
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
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

# Write kubeconfig before any Kubernetes resources
resource "null_resource" "get_kubeconfig" {
  triggers = {
    cluster  = google_container_cluster.primary.name
    location = google_container_cluster.primary.location
    project  = local.actual_project
  }

  provisioner "local-exec" {
    command = "KUBECONFIG='${local.kubeconfig_path}' gcloud container clusters get-credentials ${google_container_cluster.primary.name} --location ${google_container_cluster.primary.location} --project ${local.actual_project}"
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