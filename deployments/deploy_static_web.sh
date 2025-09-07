#!/usr/bin/env bash
set -euo pipefail

# Minify web/index.html, web/app.js, web/styles.css into a temp dir and upload to GCS.
# Note: This script does NOT create or modify any Load Balancer. Use your existing GKE Ingress.
#
# Usage:
#   STATIC_VERSION=v1 \                     # optional; defaults to v1; changes static asset paths
#   PROJECT_ID=my-project \
#   REGION=us-central1 \
#   STATIC_BUCKET=shortener-static-my-project \   # optional; defaults to shortener-static-$PROJECT_ID
#   API_BASE="https://short.example.com" \       # optional; sets API base in app.js (for cross-origin)
#   ./deployments/deploy_static_web.sh
#
# Requires: gcloud, gsutil, kubectl (not used here), node+npm (for npx esbuild)

STATIC_VERSION="${STATIC_VERSION:-v1}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
STATIC_BUCKET="${STATIC_BUCKET:-shortener-static-${PROJECT_ID}-${STATIC_VERSION}-${REGION}}"
API_BASE="${API_BASE:-}"               # If empty, app uses relative URLs to the same host.
# No LB/CDN provisioning in this script.

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required (export PROJECT_ID=...)" >&2; exit 1
fi

# Resolve repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SRC_DIR="${REPO_ROOT}/web"
INDEX_SRC="${SRC_DIR}/index.html"
APP_SRC="${SRC_DIR}/app.js"
CSS_SRC="${SRC_DIR}/styles.css"

for f in "${INDEX_SRC}" "${APP_SRC}" "${CSS_SRC}"; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f"; exit 1; }
done

command -v gcloud >/dev/null || { echo "ERROR: gcloud not found"; exit 1; }
command -v gsutil >/dev/null || { echo "ERROR: gsutil not found"; exit 1; }
command -v npx >/dev/null || { echo "ERROR: npx (node/npm) not found"; exit 1; }

gcloud config set project "${PROJECT_ID}" >/dev/null

# Temp dir for build artifacts
BUILD_DIR="$(mktemp -d -t shortener-web-XXXXXXXX)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo "Building static site into ${BUILD_DIR} ..."
cp "${INDEX_SRC}" "${BUILD_DIR}/index.html"

# Optionally inject API_BASE into app.js before minify
APP_WORK="${BUILD_DIR}/app.js"
cp "${APP_SRC}" "${APP_WORK}"
if [[ -n "${API_BASE}" ]]; then
  # Replace: const API_BASE = "...";
  sed -E -i 's|^(\s*const\s+API_BASE\s*=\s*).*$|\1"'"${API_BASE}"'";|' "${APP_WORK}"
fi

# Minify JS/CSS with esbuild
npx --yes esbuild "${APP_WORK}" --minify --outfile="${BUILD_DIR}/app.min.js" >/dev/null
npx --yes esbuild "${CSS_SRC}" --minify --outfile="${BUILD_DIR}/styles.min.css" >/dev/null

# Update index.html to point to minified assets
sed -E -i \
  -e "s#app\.js#static/${STATIC_VERSION}/app.min.js#g" \
  -e "s#styles\.css#static/${STATIC_VERSION}/styles.min.css#g" \
  "${BUILD_DIR}/index.html"

# Create bucket if missing (Uniform access + Public)
BUCKET_URI="gs://${STATIC_BUCKET}"
if ! gsutil ls -b "${BUCKET_URI}" >/dev/null 2>&1; then
  echo "Creating bucket ${BUCKET_URI} in ${REGION} ..."
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" -b on "${BUCKET_URI}"
fi

# Make objects publicly readable (bucket-level IAM)
gsutil iam ch allUsers:objectViewer "${BUCKET_URI}" >/dev/null || true

# Upload (set gzip for text assets)
echo "Uploading files to ${BUCKET_URI} ..."
# Upload to versioned paths
gsutil -m cp -z html "${BUILD_DIR}/index.html" "${BUCKET_URI}/index.html"
gsutil -m cp -z js   "${BUILD_DIR}/app.min.js" "${BUCKET_URI}/static/${STATIC_VERSION}/app.min.js"
gsutil -m cp -z css  "${BUILD_DIR}/styles.min.css" "${BUCKET_URI}/static/${STATIC_VERSION}/styles.min.css"

# Optional: website config and cache headers
gsutil web set -m index.html "${BUCKET_URI}" >/dev/null || true
gsutil setmeta -h "Cache-Control:public,max-age=600" "${BUCKET_URI}/index.html" >/dev/null || true
gsutil setmeta -h "Cache-Control:public,max-age=86400,immutable" "${BUCKET_URI}/static/${STATIC_VERSION}/app.min.js" "${BUCKET_URI}/static/${STATIC_VERSION}/styles.min.css" >/dev/null || true

SITE_URL="https://storage.googleapis.com/${STATIC_BUCKET}/index.html"
echo "Deployed:"
echo " - ${SITE_URL}"
echo "Upload complete. If you need it at '/', either:"
echo " - Proxy '/' via your Ingress to a tiny Service (and enable BackendConfig CDN), or"
echo " - Use a Cloud HTTP(S) LB URL map with a BackendBucket for '/' (replaces Ingress)."

echo "Done."