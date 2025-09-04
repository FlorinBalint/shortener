locals {
  # Per-service overrides
  keygen_image = "keygen"
  headless_svc_port = 8083
  keygen_pod_port = 8083
}

resource "kubernetes_namespace" "shortener" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_service" "keygen_headless" {
  metadata {
    name      = "${var.app_name}-keygen-headless"
    namespace = kubernetes_namespace.shortener.metadata[0].name
    labels = {
      app = "${var.app_name}-keygen"
    }
  }
  spec {
    cluster_ip = "None"
    selector = {
      app = "${var.app_name}-keygen"
    }
    port {
      name        = "http"
      port        = local.headless_svc_port
      target_port = local.headless_svc_port
    }
  }

  depends_on = [
    kubernetes_namespace.shortener,
  ]
}

resource "kubernetes_service" "keygen-svc" {
  metadata {
    name      = "${var.app_name}-keygen-svc"
    namespace = kubernetes_namespace.shortener.metadata[0].name
    labels = {
      app = "${var.app_name}-keygen-svc"
    }
  }
  spec {
    selector = {
      app = "${var.app_name}-keygen"
    }
    port {
      name        = "http"
      port        = local.headless_svc_port
      target_port = local.headless_svc_port
    }
    type = "ClusterIP"
  }

  depends_on = [
    kubernetes_namespace.shortener,
  ]
}

resource "kubernetes_stateful_set" "keygen" {
  metadata {
    name      = "${var.app_name}-keygen"
    namespace = kubernetes_namespace.shortener.metadata[0].name
    labels = {
      app = "${var.app_name}-keygen"
    }
  }
  spec {
    service_name = kubernetes_service.keygen_headless.metadata[0].name
    replicas     = var.min_replicas

    selector {
      match_labels = {
        app = "${var.app_name}-keygen"
      }
    }
    template {
      metadata {
        labels = {
          app = "${var.app_name}-keygen"
        }
      }
      spec {
        container {
          name              = "keygen"
          image             = "${local.reg_region}-docker.pkg.dev/${local.actual_project}/${var.repo}/${local.keygen_image}:${var.image_tag}"
          image_pull_policy = "Always"
          args              = (length(var.container_args) > 0 ? var.container_args : ["-address=:8083"])
          port {
            name           = "http"
            container_port = local.keygen_pod_port
          }
          resources {
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = local.keygen_pod_port
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = local.keygen_pod_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_namespace.shortener,
  ]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "keygen-hpa" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace.shortener.metadata[0].name
  }
  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "StatefulSet"
      name        = kubernetes_stateful_set.keygen.metadata[0].name
    }
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas
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

  depends_on = [
    kubernetes_namespace.shortener,
    kubernetes_stateful_set.keygen,
  ]
}
