#!/usr/bin/env bash
# Root-level NidanEHR service operations. See README.md and service-specific docs.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
if [[ "${1:-}" == "--dev" ]]; then COMPOSE_FILE="dev.docker-compose.yml"; shift; fi

[[ -f "$COMPOSE_FILE" ]] || { echo "Compose file not found: $COMPOSE_FILE" >&2; exit 1; }
[[ -f .env ]] || { echo "Missing .env. Create it from env.template and configure it first." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required." >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else echo "Docker Compose is required." >&2; exit 1; fi

compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"; }
# The standard stack uses named profiles; wildcard activates all services.
compose_all() { compose --profile '*' "$@"; }

service_exists() { compose config --services | grep -Fxq "$1"; }
require_service() {
  service_exists "$1" || { echo "Service '$1' is not defined in $COMPOSE_FILE." >&2; return 1; }
}
service_json() {
  compose config --format json | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("services",{}).get(sys.argv[1],{})))' "$1"
}
service_has_build() {
  service_json "$1" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin).get("build") else "no")'
}
service_image() {
  service_json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("image",""))'
}
service_container() {
  local id
  id="$(compose_all ps -q "$1")"
  if [[ -z "$id" ]] || [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" != "true" ]]; then
    echo "Service '$1' has no running container. Start it first." >&2
    return 1
  fi
  printf '%s' "$id"
}
select_service() {
  local prompt="$1" selection i
  mapfile -t AVAILABLE_SERVICES < <(compose config --services)
  printf '\n%s\n' "$prompt"
  for i in "${!AVAILABLE_SERVICES[@]}"; do printf ' %2d) %s\n' "$((i+1))" "${AVAILABLE_SERVICES[$i]}"; done
  read -r -p 'Service number (q to cancel): ' selection
  [[ "$selection" =~ ^[0-9]+$ ]] || return 1
  ((selection >= 1 && selection <= ${#AVAILABLE_SERVICES[@]})) || return 1
  SELECTED_SERVICE="${AVAILABLE_SERVICES[$((selection-1))]}"
}
list_services() {
  compose config --format json | python3 -c '
import json,sys
for name,cfg in json.load(sys.stdin).get("services",{}).items():
    build=cfg.get("build")
    source=("build: "+str(build.get("context",".")) if isinstance(build,dict) else ("build: "+str(build) if build else "prebuilt image"))
    print("{:<26} {:<34} profiles={}".format(name,source+" ["+cfg.get("image","no image")+"]",",".join(cfg.get("profiles",[])) or "default"))
'
}
build_service() {
  local service="$1"
  require_service "$service"
  case "$service" in
    openmrs-backend) build_openmrs_backend ;;
    openmrs-frontend) build_openmrs_frontend ;;
    odoo) build_odoo_base ;;
    *)
      if [[ "$(service_has_build "$service")" == yes ]]; then
        compose_all build "$service"
      else
        echo "'$service' uses a prebuilt image and has no local build context in $COMPOSE_FILE."
        echo "Use Pull images, or add a documented local build context before attempting a source build."
      fi
      ;;
  esac
}
start_service() {
  local service="$1"
  require_service "$service"
  echo "Starting $service and its declared dependencies..."
  compose_all up -d "$service"
}
build_openmrs_backend() {
  require_service openmrs-backend
  if [[ "$(service_has_build openmrs-backend)" == yes ]]; then
    compose_all build openmrs-backend
  else
    local image
    image="$(service_image openmrs-backend)"
    [[ -n "$image" ]] || { echo "No OpenMRS backend image is configured." >&2; return 1; }
    echo "Development Compose has no backend build context; building the repository's custom distro Dockerfile."
    docker build -f openmrs/Dockerfile -t "$image" openmrs
  fi
  echo "Starting OpenMRS backend; Compose will start its database dependency as needed."
  compose_all up -d openmrs-backend
}
build_openmrs_frontend() {
  require_service openmrs-frontend
  local image
  image="$(service_image openmrs-frontend)"
  [[ -n "$image" ]] || { echo "No OpenMRS frontend image is configured." >&2; return 1; }
  [[ -f openmrs/frontend/Dockerfile ]] || { echo "Missing openmrs/frontend/Dockerfile." >&2; return 1; }
  echo "Building Nidan's custom O3 SPA using openmrs/frontend/Dockerfile."
  echo "This includes the bundled Nidan/Trigonal microfrontends and calendar patches."
  docker build -f openmrs/frontend/Dockerfile -t "$image" openmrs/frontend
  read -r -p "Build complete. Start/recreate openmrs-frontend now? [y/N]: " answer
  if [[ "$answer" == y || "$answer" == Y ]]; then
    compose_all up -d --no-deps openmrs-frontend
  else
    echo "Image built as $image. Start it later with: bash manage-services.sh start openmrs-frontend"
  fi
}
build_odoo_base() {
  local base_dir="${ODOO_ADDONS_REPO_DIR:-odoo/odoo_19_addons}"
  local dockerfile image
  if [[ ! -d "$base_dir" && -d ../odoo_19_addons ]]; then base_dir="../odoo_19_addons"; fi
  dockerfile="$base_dir/packages/Dockerfile"
  if [[ ! -f "$dockerfile" ]]; then
    cat >&2 <<EOF
Odoo is not built from ./odoo in this distribution. Its image is built in the
separate odoo_19_addons repository as documented in odoo/README.md.

Expected build file: $dockerfile
Initialize the odoo/odoo_19_addons submodule or set ODOO_ADDONS_REPO_DIR.
EOF
    return 1
  fi
  image="${ODOO_BASE_IMAGE:-trigonaltechnology/nidan_odoo:stable}"
  echo "Building the open-source Odoo base image from $base_dir/packages."
  docker build -f "$dockerfile" -t "$image" "$base_dir/packages"

  # The current Compose file may pin a different tag (for example :latest).
  # Tag the same locally-built base image for that configured reference too.
  local compose_image
  compose_image="$(service_image odoo)"
  if [[ -n "$compose_image" && "$compose_image" != "$image" ]]; then
    docker tag "$image" "$compose_image"
    echo "Tagged base image as the Compose-configured image: $compose_image"
  fi

  local pro_dir="${ODOO_PRIVATE_ADDONS_REPO_DIR:-../nidan_odoo_extra_addons}"
  local pro_dockerfile="$pro_dir/packages/Dockerfile"
  if [[ -f "$pro_dockerfile" ]]; then
    local pro_image="${ODOO_PRO_IMAGE:-trigonaltechnology/nidan_odoo_pro:stable}"
    echo "Building the private Pro layer after the base image: $pro_dir/packages"
    docker build -f "$pro_dockerfile" -t "$pro_image" "$pro_dir/packages"
    echo "Built $pro_image locally. No registry push was performed."
    echo "To run Pro, configure the odoo service image as $pro_image before starting it."
  else
    echo "Private Odoo addons repo not found at $pro_dir; skipped the optional Pro layer."
    echo "If needed, set ODOO_PRIVATE_ADDONS_REPO_DIR to its checkout and rerun."
  fi
  echo "Build order followed: open-source base first, private Pro layer second (when available)."
}
build_custom_modules() {
  local source_root="${OPENMRS_BACKEND_DIR:-../openmrs-backend}"
  local module dir artifact built=0 missing=0
  local -a modules=(openmrs-module-fhir2 openmrs-module-medication-administration openmrs-module-bahmni-ipd openmrs-module-attachments openmrs-module-communication openmrs-module-appointments openmrs-module-orderexpansion openmrs-module-nidancore)
  command -v mvn >/dev/null 2>&1 || { echo "Maven (mvn) is required." >&2; return 1; }
  [[ -d "$source_root" ]] || {
    echo "OpenMRS module source repository not found: $source_root" >&2
    echo "Set OPENMRS_BACKEND_DIR to the sibling openmrs-backend checkout." >&2
    return 1
  }
  mkdir -p openmrs/custom_modules
  for module in "${modules[@]}"; do
    dir="$source_root/$module"
    if [[ ! -f "$dir/pom.xml" ]]; then echo "SKIP: $module (not present)"; ((missing+=1)); continue; fi
    echo "=== Building $module ==="
    (cd "$dir" && mvn package -DskipTests)
    mapfile -t artifacts < <(find "$dir" -type f -path '*/target/*.omod' -print)
    (("${#artifacts[@]}" > 0)) || { echo "No OMOD artifact produced by $module." >&2; return 1; }
    for artifact in "${artifacts[@]}"; do
      cp -f "$artifact" openmrs/custom_modules/
      echo "Copied $(basename "$artifact")"
      ((built+=1))
    done
  done
  echo "Built/copied $built OMOD artifact(s); skipped $missing unavailable source directories."
  echo "Next: build the OpenMRS backend image so the Dockerfile includes these OMODs."
}
copy_path_to_container() {
  local cid="$1" src="$2" dst="$3"
  [[ -e "$src" ]] || { echo "Host path does not exist: $src" >&2; return 1; }
  [[ "$dst" == /* ]] || { echo "Container destination must be an absolute path: $dst" >&2; return 1; }
  if [[ -d "$src" ]]; then
    docker exec "$cid" mkdir -p "$dst"
    docker cp "$src/." "$cid:$dst/"
  else
    docker cp "$src" "$cid:$dst"
  fi
  echo "Copied $src -> $dst"
}
copy_assets() {
  local service="${1:-}" cid mapping src dst answer
  if [[ -z "$service" ]]; then
    select_service "Choose the running container that will receive files:" || return 1
    service="$SELECTED_SERVICE"
  fi
  require_service "$service"
  cid="$(service_container "$service")" || return 1

  if [[ "$service" == openmrs-frontend ]]; then
    echo
    echo "OpenMRS frontend destinations are based on its Nginx image (/usr/share/nginx/html)."
    local -a defaults=(
      "openmrs/frontend/config-core_demo.json|/usr/share/nginx/html/config-core_demo.json"
      "openmrs/frontend/resources/favicon.ico|/usr/share/nginx/html/favicon.ico"
      "openmrs/frontend/resources/clinicemr-logo.svg|/usr/share/nginx/html/clinicemr-logo.svg"
      "openmrs/frontend/resources/clinicemr-logo-white.svg|/usr/share/nginx/html/clinicemr-logo-white.svg"
    )
    for mapping in "${defaults[@]}"; do
      src="${mapping%%|*}"; dst="${mapping#*|}"
      [[ -e "$src" ]] || continue
      read -r -p "Copy $src -> $dst? [Y/n]: " answer
      if [[ "$answer" != n && "$answer" != N ]]; then copy_path_to_container "$cid" "$src" "$dst"; fi
    done
    if [[ -d openmrs/frontend/spa ]]; then
      read -r -p "Copy built SPA directory openmrs/frontend/spa into /usr/share/nginx/html (overwrite current static assets)? [y/N]: " answer
      if [[ "$answer" == y || "$answer" == Y ]]; then
        copy_path_to_container "$cid" openmrs/frontend/spa /usr/share/nginx/html
      fi
    else
      echo "No host SPA build found at openmrs/frontend/spa. Build it with the frontend build option first."
    fi
  fi

  echo
  echo "You can copy any file or directory into this container."
  echo "Enter host-path|absolute-container-path; leave blank to finish."
  while true; do
    read -r -p "Copy mapping: " mapping
    [[ -n "$mapping" ]] || break
    [[ "$mapping" == *"|"* ]] || { echo "Expected host-path|/container/path"; continue; }
    src="${mapping%%|*}"; dst="${mapping#*|}"
    copy_path_to_container "$cid" "$src" "$dst" || true
  done
  echo "Copy complete. The container was not rebuilt or recreated. Refresh the application (hard-refresh if cached)."
}
openmrs_diagnostic() {
  local cid
  require_service openmrs-backend
  cid="$(service_container openmrs-backend)" || return 1
  if docker exec "$cid" test -x /openmrs/check-initializer.sh; then
    docker exec -it "$cid" /openmrs/check-initializer.sh
  else
    echo "Initializer diagnostic is unavailable in this backend image." >&2
    return 1
  fi
}
status_all() { compose_all ps; }
logs_service() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then select_service "Select service for logs:" || return 1; service="$SELECTED_SERVICE"; fi
  require_service "$service"
  compose_all logs --tail=250 --follow "$service"
}
restart_service() {
  local service="${1:-}"
  if [[ -z "$service" ]]; then select_service "Select service to restart:" || return 1; service="$SELECTED_SERVICE"; fi
  require_service "$service"
  compose_all restart "$service"
}
pull_service() {
  local service="$1"
  require_service "$service"
  compose_all pull "$service"
}
menu() {
  while true; do
    cat <<'MENU'

NIDAN EHR - SERVICE BUILD & OPERATIONS
  1) List services, images, build contexts and profiles
  2) Build a service (OpenMRS/Odoo have documented custom build paths)
  3) Start a service and its dependencies
  4) Build OpenMRS backend and start it
  5) Build custom OpenMRS OMOD modules (FHIR2 -> medication-administration -> IPD)
  6) Build Nidan OpenMRS frontend SPA image
  7) Copy static files or the built SPA into a running container (no rebuild)
  8) Run OpenMRS Initializer diagnostic
  9) Pull an image for a selected service
 10) Show status/health for all services
 11) Follow logs for a service
 12) Restart a service
 13) Start all services, including optional profiles
 14) Exit
MENU
    read -r -p 'Choice [1-14]: ' choice
    case "$choice" in
      1) list_services ;;
      2) select_service "Select service to build:" && build_service "$SELECTED_SERVICE" ;;
      3) select_service "Select service to start:" && start_service "$SELECTED_SERVICE" ;;
      4) build_openmrs_backend ;;
      5) build_custom_modules ;;
      6) build_openmrs_frontend ;;
      7) copy_assets ;;
      8) openmrs_diagnostic ;;
      9) select_service "Select service image to pull:" && pull_service "$SELECTED_SERVICE" ;;
      10) status_all ;;
      11) logs_service ;;
      12) restart_service ;;
      13) compose_all up -d ;;
      14) return 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}
case "${1:-menu}" in
  menu) menu ;;
  list) list_services ;;
  build) build_service "${2:?Usage: $0 build SERVICE}" ;;
  start|up) start_service "${2:?Usage: $0 start SERVICE}" ;;
  build-openmrs-backend) build_openmrs_backend ;;
  build-openmrs-frontend|build-frontend) build_openmrs_frontend ;;
  build-odoo|build-odoo-base) build_odoo_base ;;
  custom-modules|build-modules) build_custom_modules ;;
  copy-assets|static-assets) copy_assets "${2:-}" ;;
  pull) pull_service "${2:?Usage: $0 pull SERVICE}" ;;
  status|ps) status_all ;;
  logs) logs_service "${2:-}" ;;
  restart) restart_service "${2:-}" ;;
  diagnose|diagnostic) openmrs_diagnostic ;;
  *)
    echo "Usage: $0 [--dev] {menu|list|build SERVICE|start SERVICE|build-openmrs-backend|build-openmrs-frontend|build-odoo|custom-modules|copy-assets [SERVICE]|pull SERVICE|status|logs [SERVICE]|restart [SERVICE]|diagnose}" >&2
    exit 2
    ;;
esac
