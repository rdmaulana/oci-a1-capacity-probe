#!/usr/bin/env bash
# oci-a1-probe-discord.v4-fixed.sh
# Probe OCI Ampere A1 capacity with Discord notifications.
# Fixed based on Oracle's official example
#
set -euo pipefail

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"; }
notify() {
  local msg="$1"
  if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      curl -s -X POST "${DISCORD_WEBHOOK_URL}" -H "Content-Type: application/json" \
        -d "$(jq -n --arg content "$msg" --arg username "OCI A1 Probe" '{content: $content, username: $username}')" >/dev/null || true
    else
      curl -s -X POST "${DISCORD_WEBHOOK_URL}" -H "Content-Type: application/json" \
        -d "{\"content\":\"${msg//\"/\\\"}\",\"username\":\"OCI A1 Probe\"}" >/dev/null || true
    fi
  fi
}

# ---- Config ----
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-1}"
MEMORY_GB="${MEMORY_GB:-6}"
IMAGE_OCID="${IMAGE_OCID:-ocid1.image.oc1.ap-singapore-1.aaaaaaaay6rp22ldj66r644xj6lnotor6ououzx2m2zwyoczcpekuratoimq}"
IMAGE_FILTER="${IMAGE_FILTER:-Canonical-Ubuntu-24.04-Minimal-aarch64-2025.07.23-0}"
AD_NAME="${AD_NAME:-rgva:AP-SINGAPORE-1-AD-1}"

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${SUBNET_OCID:?SUBNET_OCID is required}"
: "${AD_NAME:?AD_NAME is required}"

# Dependencies
if ! command -v oci >/dev/null 2>&1; then
  log "ERROR: 'oci' CLI not found."
  exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
  if command -v apt >/dev/null 2>&1; then
    sudo apt update -y && sudo apt install -y jq >/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y jq >/dev/null || true
  fi
fi

# Resolve IMAGE_OCID by exact display-name if not provided
if [[ -z "${IMAGE_OCID}" || "${IMAGE_OCID}" == "null" ]]; then
  log "Resolving IMAGE_OCID for display-name: '${IMAGE_FILTER}' ..."
  IMAGE_OCID="$(oci compute image list \
    --profile "${OCI_PROFILE}" \
    --compartment-id "${COMPARTMENT_OCID}" \
    --all \
    --query "items[?\"display-name\"=='${IMAGE_FILTER}'].id | [0]" \
    --raw-output 2>/dev/null || true)"
  if [[ -z "${IMAGE_OCID}" || "${IMAGE_OCID}" == "null" ]]; then
    log "ERROR: Exact image display-name not found in this compartment/region: ${IMAGE_FILTER}"
    log "Tip: Verify the display-name in Console → Compute → Custom Images / Images."
    exit 1
  fi
fi
log "Using IMAGE_OCID=${IMAGE_OCID}"

DISPLAY_NAME="a1-probe-$(date +%s)"
log "Attempting to launch '${SHAPE}' (OCPUs=${OCPUS}, Memory=${MEMORY_GB}GB) in AD='${AD_NAME}' ..."

# Create JSON variables using jq (following Oracle's pattern)
metadata=$(echo '{}' | jq -rc)
shape_config=$(echo '{
    "ocpus": '${OCPUS}',
    "memoryInGBs": '${MEMORY_GB}'
}' | jq -rc)

set +e
# Launch instance using Oracle's exact pattern
LAUNCH_RESULT=$(oci compute instance launch \
  --profile "${OCI_PROFILE}" \
  --availability-domain "${AD_NAME}" \
  --compartment-id "${COMPARTMENT_OCID}" \
  --display-name "${DISPLAY_NAME}" \
  --image-id "${IMAGE_OCID}" \
  --metadata "${metadata}" \
  --shape "${SHAPE}" \
  --shape-config "${shape_config}" \
  --subnet-id "${SUBNET_OCID}" \
  --assign-public-ip false \
  --wait-for-state "RUNNING" 2>/dev/null)
STATUS=$?
set -e

# Extract data from result using jq (following Oracle's pattern)
if [[ $STATUS -eq 0 ]]; then
  instance_data=$(echo "${LAUNCH_RESULT}" | jq -rc '.data')
  INSTANCE_ID=$(echo "${instance_data}" | jq -r '.id')
  
  if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "null" ]]; then
    log "ERROR: Unable to parse instance ID from launch output."
    exit 1
  fi
  
  log "Instance created: ${INSTANCE_ID} (capacity AVAILABLE)."
  
  # Immediately terminate the instance to avoid consuming free quota
  log "Terminating probe instance ..."
  oci compute instance terminate \
    --profile "${OCI_PROFILE}" \
    --instance-id "${INSTANCE_ID}" \
    --force \
    --preserve-boot-volume false \
    --wait-for-state "TERMINATED" 2>/dev/null || {
      log "Warning: Failed to terminate instance ${INSTANCE_ID}. You may need to terminate it manually."
    }
  
  log "Probe completed: capacity AVAILABLE at $(date)."
  notify "✅ OCI A1 capacity **AVAILABLE** in ${AD_NAME}. Image: ${IMAGE_FILTER}."
  exit 0
else
  # Capture error with debug info but without --debug flag
  set +e
  ERROR_OUTPUT=$(oci compute instance launch \
    --profile "${OCI_PROFILE}" \
    --availability-domain "${AD_NAME}" \
    --compartment-id "${COMPARTMENT_OCID}" \
    --display-name "${DISPLAY_NAME}" \
    --image-id "${IMAGE_OCID}" \
    --metadata "${metadata}" \
    --shape "${SHAPE}" \
    --shape-config "${shape_config}" \
    --subnet-id "${SUBNET_OCID}" \
    --assign-public-ip false 2>&1)
  set -e
  
  if echo "${ERROR_OUTPUT}" | grep -qi "Out of capacity\|OutOfCapacity\|LimitExceeded"; then
    log "No capacity available for ${SHAPE} in ${AD_NAME}."
    notify "⚠️ OCI A1 capacity **UNAVAILABLE** in ${AD_NAME}. Image: ${IMAGE_FILTER}."
    exit 2
  fi
  
  log "Launch failed with error:"
  printf "%s\n" "${ERROR_OUTPUT}"
  notify "❌ OCI A1 launch **FAILED** in ${AD_NAME}. Image: ${IMAGE_FILTER}."
  exit 1
fi