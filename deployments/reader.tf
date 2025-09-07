locals {
  reader_name  = "${var.app_name}-reader"
  reader_image = "reader"
  reader_port  = 8080
}


resource "google_service_account" "reader-sa" {
  project      = local.actual_project
  account_id   = "${var.app_name}-reader"
  display_name = "Reader Workload Identity"
}

resource "kubernetes_service_account" "reader" {
  metadata {
    name      = local.reader_name
    namespace = var.namespace
    labels = { 
      app = local.reader_name 
    }
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.reader-sa.email
    }
  }
}

resource "google_service_account_iam_member" "reader_wi" {
  service_account_id = google_service_account.reader-sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.actual_project}.svc.id.goog[${var.namespace}/${kubernetes_service_account.reader.metadata[0].name}]"

  depends_on = [kubernetes_service_account.reader]
}

resource "google_project_iam_member" "reader_datastore" {
  project = local.actual_project
  role    = "roles/datastore.viewer"
  member  = "serviceAccount:${google_service_account.reader-sa.email}"
}

resource "kubernetes_service" "reader_svc" {
  metadata {
    name      = "${local.reader_name}-svc"
    namespace = var.namespace
    labels = {
      app = local.reader_name
    }
  }
  spec {
    selector = {
      app = local.reader_name
    }
    port {
      name        = "http"
      port        = local.reader_port
      target_port = local.reader_port
    }
    type = "NodePort"
  }
}

resource "kubernetes_deployment" "reader" {
  metadata {
    name      = local.reader_name
    namespace = var.namespace
    labels = {
      app = local.reader_name
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = local.reader_name
      }
    }

    template {
      metadata {
        labels = {
          app = local.reader_name
        }
      }
      spec {
        service_account_name = kubernetes_service_account.reader.metadata[0].name

        container {
          name              = "reader"
          image             = "${local.reg_region}-docker.pkg.dev/${local.actual_project}/${var.repo}/${local.reader_image}:${var.image_tag}"
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = local.reader_port
          }

          env {
            name  = "DS_ENDPOINT"
            value = var.ds_endpoint
          }

          env {
            name  = "BIND_ADDR"
            value = ":8080"
          }

          env {
            name = "MEMCACHE_DISCOVERY_ENDPOINT"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.memcache_discovery.metadata[0].name
                key  = "MEMCACHE_DISCOVERY_ENDPOINT"
              }
            }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = local.reader_port
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = local.reader_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}
