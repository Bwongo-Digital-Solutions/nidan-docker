#!/usr/bin/env bash
# Root-level Nidan service and OpenMRS operations.
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
if [[ "${1:-}" == "--dev" ]]; then COMPOSE_FILE="dev.docker-compose.yml"; shift; fi
if [[ ! -f "$COMPOSE_FILE" ]]; then echo "Compose file not found: $COMPOSE_FILE" >&2; exit 1; fi
if [[ ! -f .env ]]; then echo "Missing .env; configure it before continuing." >&2; exit 1; fi
if ! command -v docker >/dev/null 2>&1; then echo "Docker is required." >&2; exit 1; fi
if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else echo "Docker Compose is required." >&2; exit 1; fi

compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"; }
compose_all() { compose --profile '*' "$@"; }
service_exists() { compose config --services | grep -Fxq "$1"; }
require_service() { service_exists "$1" || { echo "Service '$1' is not defined in $COMPOSE_FILE." >&2; return 1; }; }
service_has_build() {
  compose config --format json | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin).get("services",{}).get(sys.argv[1],{}).get("build") else "no")' "$1"
}
service_container() {
  local id
  id="$(compose_all ps -q "$1")"
  if [[ -z "$id" ]] || [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" != "true" ]]; then
    echo "Service '$1' has no running container. Start it first." >&2; return 1
  fi
  printf '%s' "$id"
}
list_services() {
  compose config --format json | python3 -c 'import json,sys; s=json.load(sys.stdin)["services"]; [print(f"{n:28} {("build" if c.get("build") else c.get("image","no image"))} {("profiles="+",".join(c.get("profiles",[]))) if c.get("profiles") else ""}") for n,c in s.items()]'
}
select_service() {
  local prompt="$1" selection
  mapfile -t AVAILABLE_SERVICES < <(compose config --services)
  printf '\n%s\n' "$prompt"
  local i
  for i in "${!AVAILABLE_SERVICES[@]}"; do printf ' %2d) %s\n' "$((i+1))" "${AVAILABLE_SERVICES[$i]}"; done
  read -r -p 'Service number (or q to cancel): ' selection
  [[ "$selection" =~ ^[0-9]+$ ]] || return 1
  ((selection>=1 && selection<=${#AVAILABLE_SERVICES[@]})) || return 1
  SELECTED_SERVICE="${AVAILABLE_SERVICES[$((selection-1))]}"
}
build_one() {
  require_service "$1"
  if [[ "$(service_has_build "$1")" == yes ]]; then compose_all build "$1"
  else echo "'$1' uses a prebuilt image; no local build context is configured."; fi
}
start_one() {
  require_service "$1"
  echo "Starting '$1' (Compose will use its build context if present, otherwise its configured image)."
  compose_all up --build -d "$1"
}
build_custom_modules() {
  local source_root="${OPENMRS_BACKEND_DIR:-../openmrs-backend}"
  local module dir artifact built=0 missing=0
  local -a modules=(openmrs-module-fhir2 openmrs-module-medication-administration openmrs-module-bahmni-ipd openmrs-module-attachments openmrs-module-communication openmrs-module-appointments openmrs-module-orderexpansion openmrs-module-nidancore)
  command -v mvn >/dev/null 2>&1 || { echo "Maven (mvn) is required." >&2; return 1; }
  [[ -d "$source_root" ]] || { echo "OpenMRS source not found: $source_root. Set OPENMRS_BACKEND_DIR." >&2; return 1; }
  mkdir -p openmrs/custom_modules
  for module in "${modules[@]}"; do
    dir="$source_root/$module"
    if [[ ! -f "$dir/pom.xml" ]]; then echo "SKIP: $module (source directory not present)"; ((missing+=1)); continue; fi
    echo "=== Building $module ==="
    (cd "$dir" && mvn package -DskipTests)
    mapfile -t artifacts < <(find "$dir" -type f -path '*/target/*.omod' -print)
    (("${#artifacts[@]}" > 0)) || { echo "No OMOD artifact produced by $module." >&2; return 1; }
    for artifact in "${artifacts[@]}"; do cp -f "$artifact" openmrs/custom_modules/; echo "Copied $(basename "$artifact")"; ((built+=1)); done
  done
  echo "Built/copied $built OMOD artifact(s); skipped $missing absent module source folder(s)."
}
copy_assets() {
  local service="${1:-}" mapping src dst cid
  if [[ -z "$service" ]]; then
    select_service "Select the running container to receive static assets:" || return 1
    service="$SELECTED_SERVICE"
  fi
  require_service "$service"
  cid="$(service_container "$service")" || return 1
  if [[ "$service" == openmrs-frontend ]]; then
    echo "Enter host-path:container-path mappings, one per line."
    echo "Default OpenMRS mappings are offered below; press Enter to accept each, or type a different mapping."
    local -a defaults=(
      "openmrs/frontend/config-core_demo.json:/usr/share/nginx/html/config-core_demo.json"
      "openmrs/frontend/resources/favicon.ico:/usr/share/nginx/html/favicon.ico"
      "openmrs/frontend/resources/clinicemr-logo.svg:/usr/share/nginx/html/clinicemr-logo.svg"
      "openmrs/frontend/resources/clinicemr-logo-white.svg:/usr/share/nginx/html/clinicemr-logo-white.svg"
    )
    for mapping in "${defaults[@]}"; do
      IFS=: read -r src dst <<< "$mapping"
      [[ -e "$src" ]] || continue
      read -r -p "$src -> $dst [Enter=copy, s=skip]: " answer
      [[ "$answer" == s || "$answer" == S ]] && continue
      docker cp "$src" "$cid:$dst"
      echo "Copied $src -> $service:$dst"
    done
  fi
  while true; do
    read -r -p "Additional host-path:container-path mapping (blank to finish): " mapping
    [[ -n "$mapping" ]] || break
    [[ "$mapping" == *:* ]] || { echo "Use host-path:container-path format."; continue; }
    src="${mapping%%:*}"; dst="${mapping#*:}"
    [[ -e "$src" ]] || { echo "Host path does not exist: $src"; continue; }
    [[ "$dst" == /* ]] || { echo "Container destination must be an absolute path."; continue; }
    docker cp "$src" "$cid:$dst"
    echo "Copied $src -> $service:$dst"
  done
  echo "Asset copy complete. No image rebuild or container recreation was performed."
}
openmrs_diagnostic() {
  local cid
  require_service openmrs-backend
  cid="$(service_container openmrs-backend)" || return 1
  if docker exec "$cid" test -x /openmrs/check-initializer.sh; then docker exec -it "$cid" /openmrs/check-initializer.sh
  else echo "Initializer diagnostic script is not present in this backend image." >&2; return 1; fi
}
status_all() { compose_all ps; }
logs_service() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then select_service "Select service for logs:" || return 1; service="$SELECTED_SERVICE"; fi
  require_service "$service"; compose_all logs --tail=250 --follow "$service"
}
restart_service() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then select_service "Select service to restart:" || return 1; service="$SELECTED_SERVICE"; fi
  require_service "$service"; compose_all restart "$service"
}
menu() {
  while true; do
    cat <<'MENU'

NIDAN SERVICE OPERATIONS
  1) List services, build contexts, images and profiles
  2) Build one service (local build only)
  3) Start one service (build if configured; otherwise use image)
  4) Build and start OpenMRS backend
  5) Build custom OpenMRS OMOD modules
  6) Start complete OpenMRS stack
  7) Copy static assets into a running container (no rebuild)
  8) Run OpenMRS Initializer diagnostic
  9) Show all service status/health
 10) Follow logs for a service
 11) Restart a service
 12) Start all services, including optional profiles
 13) Exit
MENU
    read -r -p 'Choice [1-13]: ' choice
    case "$choice" in
      1) list_services ;;
      2) select_service "Select service to build:" && build_one "$SELECTED_SERVICE" ;;
      3) select_service "Select service to start:" && start_one "$SELECTED_SERVICE" ;;
      4) build_one openmrs-backend && start_one openmrs-backend ;;
      5) build_custom_modules ;;
      6) start_one openmrs-frontend ;;
      7) copy_assets ;;
      8) openmrs_diagnostic ;;
      9) status_all ;;
      10) logs_service ;;
      11) restart_service ;;
      12) compose_all up --build -d ;;
      13) return 0 ;;
      *) echo 'Invalid choice.' ;;
    esac
  done
}
case "${1:-menu}" in
  menu) menu ;;
  list) list_services ;;
  build) build_one "${2:?Usage: $0 build SERVICE}" ;;
  start|up) start_one "${2:?Usage: $0 start SERVICE}" ;;
  custom-modules|build-modules) build_custom_modules ;;
  copy-assets|static-assets) copy_assets "${2:-}" ;;
  status|ps) status_all ;;
  logs) logs_service "${2:-}" ;;
  restart) restart_service "${2:-}" ;;
  diagnose|diagnostic) openmrs_diagnostic ;;
  *)
    echo "Usage: $0 [--dev] {menu|list|build SERVICE|start SERVICE|custom-modules|copy-assets [SERVICE]|status|logs [SERVICE]|restart [SERVICE]|diagnose}" >&2
    exit 2 ;;
esac
