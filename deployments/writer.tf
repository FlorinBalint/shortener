locals {
  writer_name        = "${var.app_name}-writer"
  writer_secret_name = "${var.app_name}-writer-credentials"
  writer_image       = "writer"
  writer_port        = 8081
}

resource "google_service_account" "writer-sa" {
  project      = local.actual_project
  account_id   = "${var.app_name}-writer"
  display_name = "Writer Workload Identity"
}

# Grant the GSA permissions it needs (adjust as required)
resource "google_project_iam_member" "writer_datastore" {
  project = local.actual_project
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.writer-sa.email}"
}

# Allow the KSA to impersonate the GSA via Workload Identity
resource "google_service_account_iam_member" "writer_wi" {
  service_account_id = google_service_account.writer-sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.actual_project}.svc.id.goog[${var.namespace}/${kubernetes_service_account.writer.metadata[0].name}]"

  depends_on = [kubernetes_service_account.writer]
}

resource "kubernetes_service_account" "writer" {
  metadata {
    name      = local.writer_name
    namespace = var.namespace
    labels = { app = local.writer_name }

    annotations = {
      # Bind this KSA to the GSA for Workload Identity
      "iam.gke.io/gcp-service-account" = google_service_account.writer-sa.email
    }
  }
}

resource "kubernetes_service" "writer_svc" {
  metadata {
    name      = "${local.writer_name}-svc"
    namespace = var.namespace
    labels = {
      app = local.writer_name
    }
  }
  spec {
    selector = {
      app = local.writer_name
    }
    port {
      name        = "http"
      port        = local.writer_port
      target_port = local.writer_port
    }
    type = "LoadBalancer"   // required by GCE Ingress
  }
}

resource "kubernetes_deployment" "writer" {
  metadata {
    name      = local.writer_name
    namespace = var.namespace
    labels = {
      app = local.writer_name
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = local.writer_name
      }
    }

    template {
      metadata { labels = { app = local.writer_name } }
      spec {
        service_account_name = kubernetes_service_account.writer.metadata[0].name

        container {
          name              = "writer"
          image             = "${local.reg_region}-docker.pkg.dev/${local.actual_project}/${var.repo}/${local.writer_image}:${var.image_tag}"
          image_pull_policy = "Always"

          port { 
            name = "http"
            container_port = local.writer_port 
          }

          # Remove GOOGLE_APPLICATION_CREDENTIALS and secret mount.
          # ADC will use Workload Identity automatically.
          env { 
            name = "DS_ENDPOINT"
            value = var.ds_endpoint
          }
          env { 
            name = "KEYGEN_BASE_URL"
            value = "http://${var.app_name}-keygen-headless.${var.namespace}.svc.cluster.local:8083" 
          }
          env { 
            name = "BIND_ADDR"
            value = ":8081" 
          }

          readiness_probe { 
            http_get { 
              path = "/health"
              port = local.writer_port 
            } 
            initial_delay_seconds = 3
            period_seconds = 5 
          }
          liveness_probe  { 
            http_get {
              path = "/health"
              port = local.writer_port
            } 
            initial_delay_seconds = 10
            period_seconds = 10 
          }

          resources {
            requests = {
              cpu = "50m"
              memory = "64Mi"
            }
            limits   = {
              cpu = "250m"
              memory = "128Mi"
            }
          }
        }
      }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "50%"
        max_surge       = "50%"
      }
    }
  }
}

# Add HPA v2 for the writer Deployment
resource "kubernetes_horizontal_pod_autoscaler_v2" "writer_hpa" {
  metadata {
    name      = "${local.writer_name}-hpa"
    namespace = var.namespace
    labels = {
      app = local.writer_name
    }
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.writer.metadata[0].name
    }
    min_replicas = 3
    max_replicas = 10

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }

  depends_on = [kubernetes_deployment.writer]
}