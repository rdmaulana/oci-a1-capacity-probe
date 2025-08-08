#!/usr/bin/env bash
# oci-a1-probe-discord.v3.sh
# Probe OCI Ampere A1 capacity with Discord notifications.
# Image selection uses an exact match on the image display-name provided via IMAGE_FILTER,
# or you can set IMAGE_OCID directly to skip lookup.
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

set +e
LAUNCH_JSON="$(oci compute instance launch \
  --profile "${OCI_PROFILE}" \
  --availability-domain "${AD_NAME}" \
  --compartment-id "${COMPARTMENT_OCID}" \
  --shape "${SHAPE}" \
  --shape-config '{"ocpus":'${OCPUS}',"memoryInGBs":'${MEMORY_GB}'}' \
  --display-name "${DISPLAY_NAME}" \
  --source-details '{"sourceType":"image","imageId":"'${IMAGE_OCID}'"}' \
  --subnet-id "${SUBNET_OCID}" \
  --assign-public-ip false \
  --metadata '{"user_data": null}' \
  --wait-for-state RUNNING 2>&1)"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  if echo "${LAUNCH_JSON}" | grep -qi "Out of capacity"; then
    log "No capacity available for ${SHAPE} in ${AD_NAME}."
    exit 2
  fi
  log "Launch failed with error:"
  printf "%s\n" "${LAUNCH_JSON}"
  notify "❌ OCI A1 capacity **UNAVAILABLE** in ${AD_NAME}. Image: ${IMAGE_FILTER}. \`\`\`${LAUNCH_JSON}\`\`\`"
  exit 1
fi

# Parse instance OCID
INSTANCE_ID="$(printf "%s" "${LAUNCH_JSON}" | awk -F'"' '/"id":/ {print $4; exit}')"
if [[ -z "${INSTANCE_ID}" ]]; then
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
  --preserve-boot-volume false >/dev/null

log "Probe completed: capacity AVAILABLE at $(date)."
notify "✅ OCI A1 capacity **AVAILABLE** in ${AD_NAME}. Image: ${IMAGE_FILTER}."
exit 0
