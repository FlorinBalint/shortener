terraform {
  required_version = ">= 1.4.0"
  required_providers {
    google     = { source = "hashicorp/google", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
  }
}

provider "google" {}

provider "kubernetes" {
  config_path = pathexpand("~/.kube/config")
}
