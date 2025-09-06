resource "kubernetes_ingress_v1" "shortener" {
  metadata {
    name      = "${var.app_name}-ingress"
    namespace = var.namespace
    annotations = {
      "kubernetes.io/ingress.class" = "gce"
    }
    labels = {
      app = var.app_name
    }
  }

  spec {
    default_backend {
      service {
        name = "${var.app_name}-reader-svc"
        port {
          number = 8080
        }
      }
    }

    rule {
      http {
        path {
          path      = "/write"
          path_type = "Prefix"
          backend {
            service {
              name = "${var.app_name}-writer-svc"
              port {
                number = 8081
              }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "${var.app_name}-reader-svc"
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service.reader_svc,
    kubernetes_service.writer_svc,
  ]
}