# Shortener Project

A modular URL shortener in Go with separate services for key generation, writing new short URLs, and reading/redirecting.

## Architecture (current)

- Google Cloud HTTP(S) Load Balancer (HTTPS only)
  - URL map:
    - "/" → GCS BackendBucket (index.html)
    - "/static/<version>/*" → GCS BackendBucket (CDN enabled)
    - "/write" and "/write/*" → writer BackendService
    - default → reader BackendService
  - Backends:
    - Static: google_compute_backend_bucket to a versioned bucket
      - Name: shortener-static-<project>-<version>-<region>
      - Example: shortener-static-myproj-v1-us-central1
    - Dynamic: Standalone NEGs (GCE_VM_IP_PORT) created by GKE from Service annotations (type ClusterIP)
      - BackendServices attach NEGs per zone (no NodePorts)
  - HTTPS:
    - One reserved global IP for the HTTPS forwarding rule
    - google_compute_managed_ssl_certificate using your domain(s)
    - .dev domains enforce HSTS; HTTP is not used

## Components and Endpoints

- keygen
  - GET /health → 200 OK
  - GET /generate/v1 → returns a unique key (text/plain)
- writer
  - GET /health → 200 OK
  - POST /write/v1 → JSON: {"url_target":"https://...", "url_key":"optional-custom-key"}
- reader
  - GET /health → 200 OK
  - GET /{key} → 302 redirect to the target

## Static Web

- Files in web/: index.html, app.js, styles.css
- index.html references versioned asset paths:
  - /static/<version>/app.min.js
  - /static/<version>/styles.min.css
- GCLB routes /static/<version>/* and "/" to the bucket.

Deploy/minify/upload (script):
- deployments/deploy_static_web.sh publishes:
  - index.html → gs://shortener-static-<project>-<version>-<region>/index.html
  - app.min.js → gs://.../static/<version>/app.min.js
  - styles.min.css → gs://.../static/<version>/styles.min.css
- Bump STATIC_VERSION to roll a new asset version (CDN-busting).
- Terraform must use the same static_version to route correctly (or set static_bucket explicitly).

Example:
```
cd deployments
export STATIC_VERSION=v1
export API_BASE="https://example.com"
./deploy_static_web.sh
```

## Provisioning order (required dependencies)

0) Prereqs
- gcloud auth application-default login
- gcloud config set project YOUR_PROJECT
- terraform init -upgrade in deployments/

1) Data layer (before Kubernetes)
- Datastore/Firestore (Datastore mode):
```
cd deployments
./setup_url_store.sh YOUR_PROJECT
```
- Memorystore for Memcached (ensure PSA on the intended VPC):
```
cd deployments
PROJECT_ID=YOUR_PROJECT \
REGION=us-central1 \
NETWORK=default \
INSTANCE_ID=shortener-memcache \
NODE_COUNT=3 NODE_MEMORY=2GB NODE_CPU=1 \
./setup_url_cache.sh
```

2) Create the GKE cluster
- If Terraform manages it here:
```
terraform apply -target=google_container_cluster.primary
```
- Or create externally and ensure kubeconfig is pointing to it.

3) Deploy Kubernetes resources (namespace, SAs, Deployments, Services)
```
terraform apply \
  -target=kubernetes_namespace.shortener \
  -target=kubernetes_service_account.reader \
  -target=kubernetes_service_account.writer \
  -target=kubernetes_deployment.reader \
  -target=kubernetes_deployment.writer \
  -target=kubernetes_service.reader_svc \
  -target=kubernetes_service.writer_svc
kubectl -n shortener get pods
```

4) Wait for NEGs (created by GKE from the Services)
```
kubectl -n shortener get svc shortener-reader-svc  -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}'; echo
kubectl -n shortener get svc shortener-writer-svc  -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}'; echo
gcloud compute network-endpoint-groups list
```

5) Upload static assets (versioned) to the bucket
```
cd deployments
export STATIC_VERSION=v1
export API_BASE="https://example.com"
./deploy_static_web.sh
```

6) Apply the Load Balancer (BackendBucket, BackendServices, URL map, HTTPS)
- Ensure Terraform uses the same version you uploaded and your domains for SSL:
```
export TF_VAR_static_version="${STATIC_VERSION}"
export TF_VAR_ssl_domains='["short.example.dev"]'
terraform apply
```

7) Configure DNS → LB IP (HTTPS only) and wait for the managed cert to be ACTIVE
```
cd deployments
./configure_dns.sh -d example.dev -f shortener-https-fr -H short --with-www
gcloud compute ssl-certificates describe shortener-managed-cert --global --format='value(managed.status)'
```

## DNS and SSL

- Use deployments/configure_dns.sh to create a Cloud DNS zone and point your domain to the LB IP.
- Managed SSL cert will turn ACTIVE after DNS resolves to the HTTPS IP.

## Build and Push Images

Writer:
- Dockerfile: build/package/writer/Dockerfile
- Script: build/package/writer/build_and_push.sh

Keygen:
- Dockerfile: build/package/keygen/Dockerfile
- Script: build/package/keygen/build_and_push.sh

Example:
```
PROJECT_ID=your-project \
REGION=us-central1 \
REPO=shortener \
IMAGE=writer \
TAG=1.0.0 \
./build/package/writer/build_and_push.sh
```

## Local/Cluster Testing

Inside the cluster:
```
kubectl -n shortener run curl --rm -it --image=curlimages/curl --restart=Never -- \
  sh -lc 'curl -i http://shortener-writer-svc:8081/health'
```

Via LB:
```
LB_IP=$(gcloud compute forwarding-rules describe shortener-https-fr --global --format='value(IPAddress)')
HOST="short.example.dev"
curl -I -H "Host: ${HOST}" "https://${HOST}/"
curl -I -H "Host: ${HOST}" "https://${HOST}/static/v1/app.min.js"
curl -I -H "Host: ${HOST}" "https://${HOST}/write/health"
```

## Troubleshooting

- BackendService shows “0 backends”:
  - Apply K8s Services first; wait until Services have neg-status.
  - Re-run `terraform apply`.
  - List NEGs: `gcloud compute network-endpoint-groups list`
- Static 404:
  - TF_VAR_static_version must match STATIC_VERSION used when uploading.
  - URL map must include `/static/<version>/*` → BackendBucket.
  - Verify object: `gsutil ls gs://shortener-static-<project>-<version>-<region>/static/<version>/app.min.js`
- Managed cert stuck PROVISIONING:
  - DNS A record must point to the HTTPS forwarding rule IP.
  - Wait up to ~15 minutes.
- .dev domain:
  - HSTS enforced; HTTPS-only is expected.
