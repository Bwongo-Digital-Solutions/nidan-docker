#!/usr/bin/env bash
#
# Copy already-built OpenMRS assets and/or gateway static assets into running
# nginx containers. No image build, container recreation, or restart is done.
#
# Usage:
#   bash scripts/copy-openmrs-frontend-assets.sh
# #   bash scripts/copy-openmrs-frontend-assets.sh --spa-dir /path/to/built/spa
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="${ROOT_DIR}/openmrs/frontend"
PROXY_DIR="${ROOT_DIR}/proxy"
OPENMRS_CONTAINER="${OPENMRS_FRONTEND_CONTAINER:-nidan-openmrs-frontend}"
OPENMRS_HTML_DIR="/usr/share/nginx/html"
GATEWAY_HTML_DIR="/usr/share/nginx/html"
GATEWAY_TEMPLATE_DIR="/etc/nginx/templates"
SPA_DIR=""
COPY_PROXY_ASSETS=true

usage() {
  cat <<'USAGE'
Copy static files into running NIDAN nginx containers without rebuilding them.

Options:
  --spa-dir DIR    Also copy an existing, already-built OpenMRS SPA directory.
  --no-proxy-assets  Skip copying proxy portal assets (copied by default).
  -h, --help       Show this help.

Environment:
  OPENMRS_FRONTEND_CONTAINER   OpenMRS frontend container (default: nidan-openmrs-frontend)
  GATEWAY_CONTAINER            Gateway container (auto-detected from Compose if unset)

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
    --no-proxy-assets)
      COPY_PROXY_ASSETS=false
      shift
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

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: docker is not installed or not in PATH" >&2
  exit 1
}

# Validate the source configuration before touching the OpenMRS container.
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

docker inspect "$OPENMRS_CONTAINER" >/dev/null 2>&1 || {
  echo "ERROR: OpenMRS frontend container '$OPENMRS_CONTAINER' does not exist." >&2
  exit 1
}
[[ "$(docker inspect -f '{{.State.Running}}' "$OPENMRS_CONTAINER")" == "true" ]] || {
  echo "ERROR: OpenMRS frontend container '$OPENMRS_CONTAINER' is not running." >&2
  exit 1
}

if [[ -n "$SPA_DIR" ]]; then
  [[ -d "$SPA_DIR" && -s "${SPA_DIR}/index.html" ]] || {
    echo "ERROR: The supplied SPA directory must exist and contain index.html: $SPA_DIR" >&2
    exit 1
  }
  echo "Copying prebuilt OpenMRS SPA files from: $SPA_DIR"
  tar -C "$SPA_DIR" -cf - . | docker exec -i "$OPENMRS_CONTAINER" tar -C "$OPENMRS_HTML_DIR" -xf -
else
  echo "Keeping the currently installed OpenMRS JavaScript/CSS bundles (no --spa-dir supplied)."
fi

OPENMRS_ASSETS=(
  "$CONFIG"
  "${FRONTEND_DIR}/resources/clinicemr-logo.svg"
  "${FRONTEND_DIR}/resources/clinicemr-logo-white.svg"
  "${FRONTEND_DIR}/resources/billing-logo.jpg"
)
for file in "${OPENMRS_ASSETS[@]}"; do
  [[ -s "$file" ]] || { echo "ERROR: Missing OpenMRS asset: $file" >&2; exit 1; }
done

docker exec "$OPENMRS_CONTAINER" mkdir -p /tmp/nidan-frontend-assets
for file in "${OPENMRS_ASSETS[@]}"; do
  docker cp "$file" "$OPENMRS_CONTAINER:/tmp/nidan-frontend-assets/$(basename "$file")"
done
docker exec "$OPENMRS_CONTAINER" sh -eu -c '
  install -m 0644 /tmp/nidan-frontend-assets/config-core_demo.json "'"$OPENMRS_HTML_DIR"'/config-core_demo.json"
  install -m 0644 /tmp/nidan-frontend-assets/clinicemr-logo.svg "'"$OPENMRS_HTML_DIR"'/clinicemr-logo.svg"
  install -m 0644 /tmp/nidan-frontend-assets/clinicemr-logo-white.svg "'"$OPENMRS_HTML_DIR"'/clinicemr-logo-white.svg"
  install -m 0644 /tmp/nidan-frontend-assets/billing-logo.jpg "'"$OPENMRS_HTML_DIR"'/billing-logo.jpg"
  rm -rf /tmp/nidan-frontend-assets
'
echo "OpenMRS runtime config and branding copied."

if [[ "$COPY_PROXY_ASSETS" == true ]]; then
  [[ -d "${PROXY_DIR}/assets" ]] || { echo "ERROR: Missing ${PROXY_DIR}/assets" >&2; exit 1; }
  PROXY_FILES=(
    "${PROXY_DIR}/clinicemr-logo.svg"
    "${PROXY_DIR}/clinicemr-logo-white.svg"
    "${PROXY_DIR}/favicon.ico"
  )
  for file in "${PROXY_FILES[@]}"; do
    [[ -s "$file" ]] || { echo "ERROR: Missing proxy asset: $file" >&2; exit 1; }
  done

  GATEWAY="${GATEWAY_CONTAINER:-}"
  if [[ -z "$GATEWAY" ]]; then
    GATEWAY="$(docker ps --filter 'label=com.docker.compose.service=gateway' --format '{{.Names}}' | head -n1)"
  fi
  [[ -n "$GATEWAY" ]] || {
    echo "ERROR: Could not find a running Compose gateway. Set GATEWAY_CONTAINER explicitly." >&2
    exit 1
  }
  docker inspect "$GATEWAY" >/dev/null 2>&1 || {
    echo "ERROR: Gateway container '$GATEWAY' does not exist." >&2
    exit 1
  }
  [[ "$(docker inspect -f '{{.State.Running}}' "$GATEWAY")" == "true" ]] || {
    echo "ERROR: Gateway container '$GATEWAY' is not running." >&2
    exit 1
  }

  echo "Copying proxy static assets to gateway: $GATEWAY"
  docker exec "$GATEWAY" mkdir -p "$GATEWAY_HTML_DIR/assets"
  tar -C "${PROXY_DIR}/assets" -cf - . | docker exec -i "$GATEWAY" tar -C "$GATEWAY_HTML_DIR/assets" -xf -

  # The gateway's index template is COPY'd into the image by proxy/Dockerfile,
  # not bind-mounted by Compose. Copy the current host version explicitly before
  # rendering it; otherwise the container keeps serving the older baked-in page.
  for file in "${PROXY_FILES[@]}"; do
    docker cp "$file" "$GATEWAY:/tmp/$(basename "$file")"
  done
  docker cp "${PROXY_DIR}/index.html.template" "$GATEWAY:/tmp/index.html.template"

  # Keep root-level image assets referenced by the portal in sync as well.
  for file in "${PROXY_DIR}/nidan-logo.png" "${PROXY_DIR}/trigonal-logo.png"; do
    if [[ -s "$file" ]]; then
      docker cp "$file" "$GATEWAY:/tmp/$(basename "$file")"
    fi
  done

  docker exec "$GATEWAY" sh -eu -c '
    install -m 0644 /tmp/clinicemr-logo.svg /usr/share/nginx/html/clinicemr-logo.svg
    install -m 0644 /tmp/clinicemr-logo-white.svg /usr/share/nginx/html/clinicemr-logo-white.svg
    install -m 0644 /tmp/favicon.ico /usr/share/nginx/html/favicon.ico
    if [ -f /tmp/nidan-logo.png ]; then
      install -m 0644 /tmp/nidan-logo.png /usr/share/nginx/html/nidan-logo.png
    fi
    if [ -f /tmp/trigonal-logo.png ]; then
      install -m 0644 /tmp/trigonal-logo.png /usr/share/nginx/html/trigonal-logo.png
    fi

    # Render the freshly copied host template using the gateway's current
    # environment. Only substitute the Odoo URL so JavaScript/CSS dollar signs
    # and other template content remain untouched.
    envsubst '\''${DASHBOARD_ODOO_URL}'\'' < /tmp/index.html.template > /usr/share/nginx/html/index.html
    rm -f /tmp/clinicemr-logo.svg /tmp/clinicemr-logo-white.svg /tmp/favicon.ico
    rm -f /tmp/nidan-logo.png /tmp/trigonal-logo.png /tmp/index.html.template
  '
  echo "Proxy assets copied and portal index regenerated."
fi

echo
echo "Static asset copy completed. No image was rebuilt and no container was restarted."
echo "Hard-refresh the browser (Ctrl+Shift+R) to load updated files."
