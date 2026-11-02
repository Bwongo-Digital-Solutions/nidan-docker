#!/usr/bin/env bash
#
# Copy already-built OpenMRS SPA files and NIDAN branding/configuration into
# the running nginx frontend container. This deliberately does not build an
# image, recreate the container, or restart any services.
#
# Usage:
#   ./scripts/copy-openmrs-frontend-assets.sh
#   ./scripts/copy-openmrs-frontend-assets.sh --spa-dir /path/to/built/spa
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="${ROOT_DIR}/openmrs/frontend"
CONTAINER="${OPENMRS_FRONTEND_CONTAINER:-nidan-openmrs-frontend}"
HTML_DIR="/usr/share/nginx/html"
SPA_DIR=""

usage() {
  cat <<'USAGE'
Copy OpenMRS frontend static files into the running frontend container.

Options:
  --spa-dir DIR   Also copy the contents of an existing, already-built SPA
                  directory (for example openmrs/frontend/spa).
  -h, --help      Show this help.

Environment:
  OPENMRS_FRONTEND_CONTAINER   Container name (default: nidan-openmrs-frontend)

The script never runs docker build, docker compose up, or restarts containers.
USAGE
}

while (($#)); do
  case "$1" in
    --spa-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --spa-dir requires a directory" >&2; exit 2; }
      SPA_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Only copy a SPA bundle when the caller explicitly supplies --spa-dir.
# The standard Docker build keeps the compiled SPA inside the image, so a
# local openmrs/frontend/spa directory is not expected to exist.

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is not installed or not in PATH" >&2
  exit 1
}

docker inspect "$CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: frontend container '$CONTAINER' does not exist." >&2
  echo "Start the OpenMRS frontend once, then rerun this script." >&2
  exit 1
}

RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER")"
[[ "$RUNNING" == "true" ]] || {
  echo "ERROR: frontend container '$CONTAINER' is not running." >&2
  exit 1
}

# Validate the source configuration before touching the live container.
CONFIG="${FRONTEND_DIR}/config-core_demo.json"
[[ -s "$CONFIG" ]] || { echo "ERROR: Missing $CONFIG" >&2; exit 1; }
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$CONFIG" >/dev/null
elif command -v jq >/dev/null 2>&1; then
  jq empty "$CONFIG"
else
  echo "ERROR: Install python3 or jq to validate config-core_demo.json" >&2
  exit 1
fi

if [[ -n "$SPA_DIR" ]]; then
  [[ -d "$SPA_DIR" && -s "${SPA_DIR}/index.html" ]] || {
    echo "ERROR: The supplied SPA directory must exist and contain index.html: $SPA_DIR" >&2
    exit 1
  }
  echo "Copying prebuilt SPA files from: $SPA_DIR"
  # Stream the existing build into nginx; no image build or container restart.
  tar -C "$SPA_DIR" -cf - . | docker exec -i "$CONTAINER" tar -C "$HTML_DIR" -xf -
else
  echo "No --spa-dir supplied; keeping the currently installed SPA JavaScript/CSS bundles."
fi

# Copy the source-controlled runtime config and branding files.
ASSETS=(
  "$CONFIG"
  "${FRONTEND_DIR}/resources/clinicemr-logo.svg"
  "${FRONTEND_DIR}/resources/clinicemr-logo-white.svg"
  "${FRONTEND_DIR}/resources/billing-logo.jpg"
)

for file in "${ASSETS[@]}"; do
  [[ -s "$file" ]] || { echo "ERROR: Missing asset: $file" >&2; exit 1; }
done

docker exec "$CONTAINER" mkdir -p /tmp/nidan-frontend-assets
for file in "${ASSETS[@]}"; do
  docker cp "$file" "$CONTAINER:/tmp/nidan-frontend-assets/$(basename "$file")"
done

docker exec "$CONTAINER" sh -eu -c '
  install -m 0644 /tmp/nidan-frontend-assets/config-core_demo.json "'"$HTML_DIR"'/config-core_demo.json"
  install -m 0644 /tmp/nidan-frontend-assets/clinicemr-logo.svg "'"$HTML_DIR"'/clinicemr-logo.svg"
  install -m 0644 /tmp/nidan-frontend-assets/clinicemr-logo-white.svg "'"$HTML_DIR"'/clinicemr-logo-white.svg"
  install -m 0644 /tmp/nidan-frontend-assets/billing-logo.jpg "'"$HTML_DIR"'/billing-logo.jpg"
  rm -rf /tmp/nidan-frontend-assets
'

echo
echo "Frontend static files copied successfully to $CONTAINER:$HTML_DIR"
echo "No Docker image was rebuilt and no container was restarted."
echo "Hard-refresh the browser (Ctrl+Shift+R) to load the updated files."
