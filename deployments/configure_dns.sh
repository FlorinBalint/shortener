#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 -d <domain> [-f <forwarding-rule>] [-i <ip>] [-z <zone>] [-p <project>] [-H <host>] [--with-www] [-t <ttl>]"
  echo "  -d  Domain (e.g., example.com) [required]"
  echo "  -f  Global forwarding rule name to read LB IP (e.g., shortener-http-fr)"
  echo "  -i  LB IP address (use instead of -f)"
  echo "  -z  Cloud DNS zone name (default: dns-<domain-with-dashes>)"
  echo "  -p  GCP project (default: gcloud active project)"
  echo "  -H  Host label to create as A record (e.g., short -> short.example.com) [optional]"
  echo "      If omitted, only apex A record is created."
  echo "  --with-www  Also create www CNAME to apex"
  echo "  -t  TTL seconds (default: 300)"
  exit 1
}

DOMAIN=""
FWD_RULE=""
IP=""
ZONE=""
PROJECT="$(gcloud config get-value project --quiet 2>/dev/null || true)"
HOST_LABEL=""
WITH_WWW="false"
TTL="300"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DOMAIN="$2"; shift 2;;
    -f) FWD_RULE="$2"; shift 2;;
    -i) IP="$2"; shift 2;;
    -z) ZONE="$2"; shift 2;;
    -p) PROJECT="$2"; shift 2;;
    -H) HOST_LABEL="$2"; shift 2;;
    --with-www) WITH_WWW="true"; shift 1;;
    -t) TTL="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -n "$DOMAIN" ]] || usage
[[ -n "$PROJECT" ]] || { echo "ERROR: No project set. Use -p or `gcloud config set project ...`"; exit 1; }

gcloud config set project "$PROJECT" >/dev/null

# Normalize domain and zone
DOMAIN_NODOT="${DOMAIN%.}"
DOMAIN_DOT="${DOMAIN_NODOT}."
ZONE="${ZONE:-dns-${DOMAIN_NODOT//./-}}"

# Resolve IP
if [[ -z "$IP" ]]; then
  [[ -n "$FWD_RULE" ]] || { echo "ERROR: provide -f <forwarding-rule> or -i <ip>"; exit 1; }
  IP="$(gcloud compute forwarding-rules describe "$FWD_RULE" --global --format='value(IPAddress)')"
fi
[[ -n "$IP" ]] || { echo "ERROR: could not resolve LB IP"; exit 1; }

echo "Project:  $PROJECT"
echo "Domain:   $DOMAIN_DOT"
echo "Zone:     $ZONE"
echo "LB IP:    $IP"
[[ -n "$HOST_LABEL" ]] && echo "Host:     ${HOST_LABEL}.${DOMAIN_DOT}"
[[ "$WITH_WWW" == "true" ]] && echo "Also creating: www.${DOMAIN_DOT} -> CNAME ${DOMAIN_DOT}"
echo

# Ensure zone exists
if ! gcloud dns managed-zones describe "$ZONE" >/dev/null 2>&1; then
  echo "Creating managed zone '$ZONE' for $DOMAIN_DOT ..."
  gcloud dns managed-zones create "$ZONE" \
    --dns-name="$DOMAIN_DOT" \
    --description="Zone for ${DOMAIN_NODOT}"
  echo "Nameservers (set at your registrar):"
  gcloud dns managed-zones describe "$ZONE" --format='value(nameServers)'
  echo
fi

# Helper: upsert A record
upsert_a() {
  local name="$1"  # FQDN with trailing dot
  local ttl="$2"
  local ip="$3"
  if gcloud dns record-sets list --zone="$ZONE" --name="$name" --type=A --format='value(rrdatas[0])' | grep -qE '^[0-9.]+'; then
    echo "Updating A $name -> $ip"
    gcloud dns record-sets update "$name" --zone="$ZONE" --type=A --ttl="$ttl" --rrdatas="$ip"
  else
    echo "Creating A $name -> $ip"
    gcloud dns record-sets create "$name" --zone="$ZONE" --type=A --ttl="$ttl" --rrdatas="$ip"
  fi
}

# Helper: upsert CNAME
upsert_cname() {
  local name="$1"   # FQDN with trailing dot
  local ttl="$2"
  local target="$3" # FQDN with trailing dot
  if gcloud dns record-sets list --zone="$ZONE" --name="$name" --type=CNAME --format='value(rrdatas[0])' | grep -q '.'; then
    echo "Updating CNAME $name -> $target"
    gcloud dns record-sets update "$name" --zone="$ZONE" --type=CNAME --ttl="$ttl" --rrdatas="$target"
  else
    echo "Creating CNAME $name -> $target"
    gcloud dns record-sets create "$name" --zone="$ZONE" --type=CNAME --ttl="$ttl" --rrdatas="$target"
  fi
}

# Apex A record
upsert_a "$DOMAIN_DOT" "$TTL" "$IP"

# Optional host A record (e.g., short.example.com.)
if [[ -n "$HOST_LABEL" ]]; then
  upsert_a "${HOST_LABEL}.${DOMAIN_DOT}" "$TTL" "$IP"
fi

# Optional www CNAME to apex
if [[ "$WITH_WWW" == "true" ]]; then
  upsert_cname "www.${DOMAIN_DOT}" "$TTL" "$DOMAIN_DOT"
fi

echo
echo "Done. Test with:"
echo "  curl -I -H 'Host: ${HOST_LABEL:+${HOST_LABEL}.}${DOMAIN_DOT}' http://${IP}/"
echo "  curl -I -H 'Host: ${HOST_LABEL:+${HOST_LABEL}.}${DOMAIN_DOT}' http://${IP}/static/v1/app.min.js"
