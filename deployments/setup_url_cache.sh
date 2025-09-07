#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   PROJECT_ID=my-project \
#   REGION=us-central1 \
#   NETWORK=default \
#   INSTANCE_ID=shortener-memcache \
#   NODE_COUNT=1 \
#   NODE_MEMORY=2GB \
#   NODE_CPU=1 \
#   ZONES=us-central1-a,us-central1-b \
#   LABELS=env=prod,app=shortener \
#   PARAMETERS=max_item_size=4m,chunk_size=96 \
#   RANGE_NAME=google-managed-services-default \
#   RANGE_PREFIX_LEN=24 \
#   NAMESPACE=shortener \
#   ./deployments/setup_url_cache.sh

PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
NETWORK="${NETWORK:-default}"
INSTANCE_ID="${INSTANCE_ID:-shortener-memcache}"
NODE_COUNT="${NODE_COUNT:-3}"        # 1..20
NODE_MEMORY="${NODE_MEMORY:-2GB}"    # e.g., 1GB,2GB,4GB,…
NODE_CPU="${NODE_CPU:-2}"            # REQUIRED by API (e.g., 1,2,4)
ZONES="${ZONES:-}"                   # comma-separated, optional
LABELS="${LABELS:-}"                 # key=val,key2=val2
PARAMETERS="${PARAMETERS:-}"         # memcached params, e.g. max_item_size=4m
RANGE_NAME="${RANGE_NAME:-google-managed-services-${NETWORK}}"
RANGE_PREFIX_LEN="${RANGE_PREFIX_LEN:-24}"
NAMESPACE="${NAMESPACE:-shortener}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required" >&2; exit 1
fi
if [[ -z "${NODE_CPU}" ]]; then
  echo "ERROR: NODE_CPU is required (--node-cpu)" >&2; exit 1
fi

echo "Project:  ${PROJECT_ID}"
echo "Region:   ${REGION}"
echo "Network:  ${NETWORK}"
echo "Instance: ${INSTANCE_ID}"
echo "Nodes:    ${NODE_COUNT} x ${NODE_MEMORY}, CPU=${NODE_CPU}"
echo "Range:    ${RANGE_NAME} (/${RANGE_PREFIX_LEN})"
gcloud config set project "${PROJECT_ID}" >/dev/null

# Resolve authorized network to projects/<project>/global/networks/<network>
if [[ "${NETWORK}" == projects/*/global/networks/* ]]; then
  AUTH_NET="${NETWORK}"
else
  AUTH_NET_RAW="$(gcloud compute networks describe "${NETWORK}" --format='value(selfLink)' 2>/dev/null || true)"
  if [[ -n "${AUTH_NET_RAW}" ]]; then
    AUTH_NET="$(echo "${AUTH_NET_RAW}" | sed -E 's#^https?://[^/]+/##')"  # strip https://.../
    AUTH_NET="${AUTH_NET#compute/v1/}"
    AUTH_NET="${AUTH_NET#compute/beta/}"
  else
    AUTH_NET="projects/${PROJECT_ID}/global/networks/${NETWORK}"
  fi
fi
echo "Authorized network: ${AUTH_NET}"

# Derive network name for peering commands
NETWORK_NAME="${NETWORK}"
if [[ "${AUTH_NET}" == projects/*/global/networks/* ]]; then
  NETWORK_NAME="${AUTH_NET##*/}"
fi

echo "Enabling APIs..."
gcloud services enable memcache.googleapis.com servicenetworking.googleapis.com

# Ensure Private Service Access (Service Networking) is configured
if ! gcloud compute addresses describe "${RANGE_NAME}" --global >/dev/null 2>&1; then
  echo "Creating reserved IP range '${RANGE_NAME}' for Service Networking..."
  gcloud compute addresses create "${RANGE_NAME}" \
    --global \
    --purpose=VPC_PEERING \
    --prefix-length="${RANGE_PREFIX_LEN}" \
    --network="${NETWORK_NAME}"
else
  echo "Reserved range '${RANGE_NAME}' already exists."
fi

# Connect VPC peering to Service Networking if not active
if ! gcloud services vpc-peerings describe \
      --service=servicenetworking.googleapis.com \
      --network="${NETWORK_NAME}" \
      --region="${REGION}" >/dev/null 2>&1; then
  echo "Enabling VPC Peering for Service Networking..."
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --network="${NETWORK_NAME}" \
    --ranges="${RANGE_NAME}" \
    --project="${PROJECT_ID}"
else
  echo "VPC Peering for Service Networking is already enabled."
fi

if gcloud memcache instances describe "${INSTANCE_ID}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Memcached instance '${INSTANCE_ID}' already exists. Reusing."
else
  echo "Creating Memcached instance '${INSTANCE_ID}'..."
  create_args=(
    "--region=${REGION}"
    "--node-count=${NODE_COUNT}"
    "--node-memory=${NODE_MEMORY}"
    "--node-cpu=${NODE_CPU}"
    "--authorized-network=${AUTH_NET}"
  )
  [[ -n "${ZONES}"   ]] && create_args+=("--zones=${ZONES}")
  [[ -n "${LABELS}"     ]] && create_args+=("--labels=${LABELS}")
  [[ -n "${PARAMETERS}" ]] && create_args+=("--parameters=${PARAMETERS}")

  gcloud memcache instances create "${INSTANCE_ID}" "${create_args[@]}"
fi
