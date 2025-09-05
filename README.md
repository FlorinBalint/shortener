# Shortener Project

A modular URL shortener in Go with separate services for key generation, writing new short URLs, and reading/redirecting.

## Project Structure

```
shortener/
├── cmd/
│   ├── keygen/    # Key generation service
│   ├── reader/    # Reader/redirector service (TBD)
│   └── writer/    # Writer service (creates new entries)
├── deployments/   # Terraform for GKE, services, ingress
├── pkg/           # Shared libs (urlstore, gcputil, etc.)
└── build/
    └── package/
        ├── keygen/   # Dockerfile + build and push
        └── writer/   # Dockerfile + build and push
```

## Components and Endpoints

- keygen
  - GET /health → 200 OK
  - GET /generate/v1 → returns a unique key (text/plain)
- writer
  - GET /health → 200 OK
  - POST /write/v1 → JSON: {"url_target":"https://...", "url_key":"optional-custom-key"}
    - If url_key is omitted, writer calls keygen to generate one.
    - Returns {"url_key":"...", "url_target":"..."} on success.
- reader (TBD)
  - Will serve redirects for short links.

## Build and Push Images

Writer:
- Dockerfile: build/package/writer/Dockerfile
- Script: build/package/writer/build_and_push.sh

Keygen:
- Dockerfile: build/package/keygen/Dockerfile
- Script: build/package/keygen/build_and_push.sh

Example (writer):
```
PROJECT_ID=your-project \
REGION=us-central1 \
REPO=shortener \
IMAGE=writer \
TAG=1.0.0 \
./build/package/writer/build_and_push.sh
```
Images are pushed to: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}

## Deploy with Terraform (GKE)

- Cluster is managed or referenced via deployments/main.tf.
- Project detection uses ADC/gcloud; Kubernetes provider uses your kubeconfig.
- Keygen is a StatefulSet with a headless service; writer is a Deployment.

Writer (deployments/writer.tf):
- Runs under a dedicated KSA.
- Uses Google Workload Identity (recommended) OR (optional) a mounted SA key secret.
- HPA: min 3 replicas, max 10 (CPU target 70%).
- Service: NodePort (when fronted by a GCE Ingress) or LoadBalancer (direct external access).

Ingress (deployments/ingress.tf):
- GCE Ingress that routes:
  - /write → writer-svc
  - / → reader-svc (once implemented)

Apply:
```
cd deployments
terraform init -upgrade
terraform plan
terraform apply
```

If you already have a cluster, import it (to avoid “already exists”):
```
PROJECT=$(gcloud config get-value project)
LOCATION=us-central1-a
CLUSTER=shortener
terraform import google_container_cluster.primary "projects/${PROJECT}/locations/${LOCATION}/clusters/${CLUSTER}"
```

## Configuration

Writer reads from environment:
- GCP_PROJECT: GCP project ID
- DS_NAMESPACE: optional Datastore namespace
- DS_ENDPOINT: optional Datastore emulator/endpoint
- KEYGEN_BASE_URL: default http://shortener-keygen-headless.shortener.svc.cluster.local:8083
- BIND_ADDR: default :8081

When using Workload Identity:
- Annotate the KSA with the target GSA email.
- Ensure the GSA has roles/datastore.user (adjust as needed).

## Testing

Outside the cluster (LoadBalancer service):
```
WRITER_IP=$(kubectl -n shortener get svc shortener-writer-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -i "http://${WRITER_IP}:8081/health"

curl -i -X POST "http://${WRITER_IP}:8081/write/v1" \
  -H "Content-Type: application/json" \
  --data '{"url_target":"https://golang.org"}'
```

Inside the cluster:
```
kubectl -n shortener run curl --rm -it --image=curlimages/curl --restart=Never -- \
  sh -lc 'curl -i http://shortener-writer-svc:8081/health && \
          curl -i -X POST http://shortener-writer-svc:8081/write/v1 \
            -H "Content-Type: application/json" \
            --data "{\"url_target\":\"https://golang.org\"}"'
```

Port-forward:
```
kubectl -n shortener port-forward deploy/shortener-writer 8081:8081
curl -i http://127.0.0.1:8081/health
```
