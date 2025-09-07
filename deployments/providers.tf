terraform {
  required_version = ">= 1.4.0"
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 5.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.0" }
    kubernetes  = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    external    = { source = "hashicorp/external", version = "~> 2.3" }
  }
}

# Read current gcloud project once (no dependency on Google provider)
data "external" "gcloud_project" {
  program = ["bash", "-lc", "printf '{\"project\":\"%s\"}' \"$(gcloud config get-value project --quiet)\""]
}

provider "google" {
  # If var.project_id is non-empty, use it; else use gcloud project; else leave null
  project = var.project_id != "" ? var.project_id : lookup(data.external.gcloud_project.result, "project", null)
  region  = local.gcp_region
}

provider "google-beta" {
  project = var.project_id != "" ? var.project_id : lookup(data.external.gcloud_project.result, "project", null)
  region  = local.gcp_region
}

provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}
