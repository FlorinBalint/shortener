// Resolve region from zonal var.location (e.g., us-central1-a -> us-central1)
locals {
  gcp_region = join("-", slice(split("-", var.location), 0, 2))
}

# Optional var; empty means "derive from gcloud"
variable "project_id" {
  description = "GCP project ID (optional; auto-detected if empty)"
  type        = string
  default     = ""
}

variable "location" {
  description = "GKE cluster location; must be a ZONE like us-central1-a"
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = length(split("-", var.location)) == 3
    error_message = "Use a ZONE (e.g., europe-west2-b). Regional values (e.g., europe-west2) are not allowed."
  }
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "shortener"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 3
}

variable "node_machine_type" {
  description = "GCE machine type for nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "node_disk_size_gb" {
  description = "Boot disk size (GB) for nodes"
  type        = number
  default     = 75
}

variable "node_disk_type" {
  description = "Boot disk type for nodes: pd-standard | pd-balanced | pd-ssd"
  type        = string
  default     = "pd-ssd"
}

# Workload parameters (no hardcoded app names)
variable "namespace" {
  description = "Kubernetes namespace for the app"
  type        = string
  default     = "shortener"
}

variable "app_name" {
  description = "Application name (used for resources: StatefulSet, Services, HPA)"
  type        = string
  default     = "shortener"
}

variable "min_replicas" {
  description = "Minimum replicas for HPA/StatefulSet"
  type        = number
  default     = 2
}

variable "max_replicas" {
  description = "Maximum replicas for HPA"
  type        = number
  default     = 5
}

variable "container_args" {
  description = "Container args (leave empty to use per-service defaults)"
  type        = list(string)
  default     = []
}

# Artifact Registry image details
variable "repo" {
  description = "Artifact Registry repository name"
  type        = string
  default     = "shortener"
}

variable "image_tag" {
  description = "Image tag to deploy"
  type        = string
  default     = "latest"
}

# If you want to force a different Artifact Registry region than the cluster's region
variable "registry_region" {
  description = "Artifact Registry region (e.g., europe-west2). Defaults to derived region from location."
  type        = string
  default     = "us-central1"
}

variable "ds_endpoint" {
  description = "Endpoint to the Datastore instance"
  type        = string
  default     = ""
}

variable "memcache_instance_id" {
  description = "Memorystore for Memcached instance ID"
  type        = string
  default     = "shortener-memcache"
}

variable "memcache_node_count" {
  description = "Number of Memcached nodes (1..20)"
  type        = number
  default     = 3
}

variable "memcache_node_cpu" {
  description = "vCPU per node (required by API: 1,2,4,...)"
  type        = number
  default     = 2
}

variable "memcache_node_memory_mb" {
  description = "Memory per node in MB (e.g., 1024, 2048, 4096)"
  type        = number
  default     = 2048
}

variable "static_bucket" {
  description = "Override GCS bucket name for static content"
  type        = string
  default     = null
}

variable "static_version" {
  description = "Version prefix for static assets and bucket naming (e.g., v1)"
  type        = string
  default     = "v1"
}

variable "reader_port" {
  description = "HTTP port exposed by reader Service"
  type        = number
  default     = 8080
}

variable "writer_port" {
  description = "HTTP port exposed by writer Service"
  type        = number
  default     = 8081
}

variable "ssl_domains" {
  description = "Domains for the managed SSL certificate (e.g., [\"short.example.com\"]). Must resolve to the LB IP."
  type        = list(string)
  default     = []
}

# Zones where your cluster runs. Leave empty to use the cluster location only.
variable "lb_zones" {
  description = "Zones to look for standalone NEGs. If empty, defaults to [var.location]."
  type        = list(string)
  default     = []
}

data "google_client_config" "current" {}

locals {
  // Prefer explicit var, then external gcloud (if defined), then provider client config
  actual_project = coalesce(
    var.project_id,
    try(data.external.gcloud_project.result.project, ""),
    try(data.google_client_config.current.project, "")
  )
}
