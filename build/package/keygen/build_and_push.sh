#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PROJECT_ID=my-gcp-project \
#   REGION=europe-west2 \
#   REPO=shortener \
#   IMAGE=keygen \
#   TAG=1.0.0 \
#   SA_KEY_FILE=/path/to/sa.json \
#   ./build/package/keygen/build_and_push.sh

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
REPO="${REPO:-shortener}"
IMAGE="${IMAGE:-keygen}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required (export PROJECT_ID=your-project)"; exit 1
fi

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
CONTEXT="${REPO_ROOT}"

# Derive TAG if not provided
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'local')"
STAMP="$(date +%Y%m%d-%H%M%S)"
TAG="${TAG:-${STAMP}-${GIT_SHA}}"

REG_DOMAIN="${REGION}-docker.pkg.dev"
FULL_IMAGE="${REG_DOMAIN}/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}"
LATEST_IMAGE="${REG_DOMAIN}/${PROJECT_ID}/${REPO}/${IMAGE}:latest"

echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "Repo:    ${REPO}"
echo "Image:   ${IMAGE}"
echo "Tag:     ${TAG}"
echo "Dockerfile: ${DOCKERFILE}"
echo "Context:    ${CONTEXT}"
echo "Full:    ${FULL_IMAGE}"

ensure_gcloud_auth() {
  # Optionally activate a service account if provided
  if [[ -n "${SA_KEY_FILE:-}" && -f "${SA_KEY_FILE}" ]]; then
    echo "Activating service account from ${SA_KEY_FILE}..."
    gcloud auth activate-service-account --key-file="${SA_KEY_FILE}"
  fi

  # Ensure an active account exists
  local acc
  acc="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [[ -z "${acc}" ]]; then
    echo "ERROR: No active gcloud account. Run 'gcloud auth login' or set SA_KEY_FILE to a service account key." >&2
    exit 1
  fi

  # Set project
  gcloud config set project "${PROJECT_ID}"

  # Ensure repo exists (idempotent)
  if ! gcloud artifacts repositories describe "${REPO}" --location="${REGION}" >/dev/null 2>&1; then
    echo "Creating Artifact Registry repo '${REPO}' in ${REGION}..."
    gcloud artifacts repositories create "${REPO}" \
      --repository-format=docker \
      --location="${REGION}" \
      --description="Shortener images" \
  fi

  # Configure docker auth helper
  gcloud auth configure-docker "${REG_DOMAIN}" -q

  # Explicit docker login using an access token (handles environments where cred helper isn’t picked up)
  local tok
  tok="$(gcloud auth print-access-token)"
  echo "${tok}" | docker login -u oauth2accesstoken --password-stdin "https://${REG_DOMAIN}"
}

ensure_gcloud_auth

docker buildx build \
  --platform=linux/amd64 \
  --build-arg VERSION="${TAG}" \
  --build-arg COMMIT="${GIT_SHA}" \
  -t "${FULL_IMAGE}" \
  -f "${DOCKERFILE}" \
  "${CONTEXT}"

docker push "${FULL_IMAGE}"
docker tag "${FULL_IMAGE}" "${LATEST_IMAGE}"
docker push "${LATEST_IMAGE}"

echo "Pushed:"
echo " - ${FULL_IMAGE}"
echo " - ${LATEST_IMAGE}"