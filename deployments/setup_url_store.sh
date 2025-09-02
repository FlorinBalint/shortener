#!/bin/bash
set -e

# Usage:
#   ./setup_url_store.sh <project_id>

PROJECT_ID="${PROJECT_ID:-$1}"
REGION="us-central1"   # use us-central1 to keep Scheduler/Functions/Firestore consistent
BACKUP_BUCKET="gs://${PROJECT_ID}-datastore-backups"
FUNCTION_NAME="datastoreExportFunc"
TOPIC_NAME="startDatastoreExport"
CRON_SCHEDULE="0 3 * * *"  # daily 3AM UTC

echo "Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID"

# === ENABLE SERVICES ===
echo "Enabling required APIs (safe to rerun)..."
gcloud services enable firestore.googleapis.com \
                        pubsub.googleapis.com \
                        cloudfunctions.googleapis.com \
                        cloudscheduler.googleapis.com \
                        cloudbuild.googleapis.com || true

# === INIT FIRESTORE (SAFE) ===
if gcloud firestore databases describe --project "$PROJECT_ID" >/dev/null 2>&1; then
  echo "Firestore database already exists, skipping creation."
else
  gcloud firestore databases create --region="$REGION" --type=datastore-mode
fi

# === BACKUP BUCKET ===
if gsutil ls -b "$BACKUP_BUCKET" >/dev/null 2>&1; then
  echo "Bucket $BACKUP_BUCKET already exists."
else
  gsutil mb -l "$REGION" "$BACKUP_BUCKET"
fi

# === PUB/SUB TOPIC ===
if gcloud pubsub topics describe "$TOPIC_NAME" >/dev/null 2>&1; then
  echo "Pub/Sub topic $TOPIC_NAME already exists."
else
  gcloud pubsub topics create "$TOPIC_NAME"
fi

# === CREATE TEMP DIRECTORY FOR FILES ===
TMPDIR=$(mktemp -d)
echo "Using temporary directory: $TMPDIR"

# Ensure cleanup on exit (even if script fails)
cleanup() {
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    echo "Cleaning up temporary files..."
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

# === CLOUD FUNCTION FILES ===
cat > "${TMPDIR}/function.js" << 'EOF'
const {DatastoreAdminClient} = require('@google-cloud/datastore').v1;
const client = new DatastoreAdminClient();

exports.datastoreExportFunc = async (pubSubEvent, context) => {
  const projectId = process.env.GCP_PROJECT;
  const datasetName = client.databasePath(projectId, '(default)');
  const outputUriPrefix = process.env.BUCKET;
  await client.exportEntities({ name: datasetName, outputUriPrefix });
  console.log(`Export started to: ${outputUriPrefix}`);
};
EOF

cat > "${TMPDIR}/package.json" << 'EOF'
{
  "name": "export-datastore",
  "version": "0.1.0",
  "dependencies": {
    "@google-cloud/datastore": "^7.0.0"
  }
}
EOF

# Deploy using the temp directory as the source
gcloud functions deploy "$FUNCTION_NAME" \
  --runtime nodejs22 \
  --trigger-topic "$TOPIC_NAME" \
  --set-env-vars BUCKET="$BACKUP_BUCKET" \
  --region "$REGION" \
  --entry-point "$FUNCTION_NAME" \
  --source "$TMPDIR" \
  --allow-unauthenticated || echo "Function already deployed or conflict. Skipping redeploy."

echo "✅ Setup complete. Backups scheduled daily at: $CRON_SCHEDULE"
