terraform {
  required_version = ">= 1.4.0"
  required_providers {
    google     = { source = "hashicorp/google", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
  }
}

provider "google" {
  project = var.project_id
}

provider "kubernetes" {
  # Use the kubeconfig written by null_resource.get_kubeconfig
  config_path = "${path.module}/.kubeconfig"
  # Do NOT force a context here; use the kubeconfig's current-context set by gcloud
}
