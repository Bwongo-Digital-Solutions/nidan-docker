#!/usr/bin/env bash
# Nidan OpenMRS lifecycle helper.
# Uses the service names, profile and dependencies defined by the selected Compose file.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
if [[ "${1:-}" == "--dev" ]]; then
  COMPOSE_FILE="dev.docker-compose.yml"
  shift
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  echo "Missing .env. Create it from env.template and configure it before continuing." >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found on PATH." >&2
  exit 1
fi
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "Docker Compose v2 plugin or docker-compose is required." >&2
  exit 1
fi

# OpenMRS services are grouped under this profile in the standard compose file.
# The dev compose file may not declare profiles; Compose safely ignores this
# profile when no services use it.
compose() { "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"; }
openmrs_compose() { compose --profile openmrs "$@"; }

service_has_build() {
  local service="$1"
  compose config --format json | python3 -c 'import json,sys; name=sys.argv[1]; print("yes" if json.load(sys.stdin).get("services",{}).get(name,{}).get("build") else "no")' "$service"
}

require_service() {
  local wanted="$1" found
  found="$(compose config --services)"
  if ! grep -Fxq "$wanted" <<<"$found"; then
    echo "Service '$wanted' is not defined in $COMPOSE_FILE." >&2
    return 1
  fi
}

check_omods() {
  local count=0
  if [[ -d openmrs/custom_modules ]]; then
    count="$(find openmrs/custom_modules -maxdepth 1 -type f -name '*.omod' | wc -l | tr -d ' ')"
  fi
  echo "Custom OMOD files found: $count"
  if [[ "$count" -eq 0 ]]; then
    echo "NOTE: openmrs/Dockerfile copies openmrs/custom_modules into the image."
    echo "If this deployment requires Nidan-built modules, place the built .omod files there before building."
    echo "The script will not invent, download, or silently skip those modules."
  fi
}

build_custom_modules() {
  local source_root="${OPENMRS_BACKEND_DIR:-../openmrs-backend}"
  local module dir artifact built=0 missing=0
  local -a modules=(
    openmrs-module-fhir2
    openmrs-module-medication-administration
    openmrs-module-bahmni-ipd
    openmrs-module-attachments
    openmrs-module-communication
    openmrs-module-appointments
    openmrs-module-orderexpansion
    openmrs-module-nidancore
  )

  if ! command -v mvn >/dev/null 2>&1; then
    echo "Maven (mvn) is required to build custom OMODs." >&2
    return 1
  fi
  if [[ ! -d "$source_root" ]]; then
    echo "OpenMRS backend source repository not found: $source_root" >&2
    echo "Set OPENMRS_BACKEND_DIR to its location, or clone it beside nidan-docker." >&2
    return 1
  fi

  mkdir -p openmrs/custom_modules
  echo "Building available custom modules from $source_root"
  echo "Build order follows the Nidan notes: FHIR2 -> medication-administration -> IPD, then the remaining modules."

  for module in "${modules[@]}"; do
    dir="$source_root/$module"
    if [[ ! -f "$dir/pom.xml" ]]; then
      echo "SKIP (source not present): $module"
      ((missing+=1))
      continue
    fi

    echo
    echo "=== Building $module ==="
    (cd "$dir" && mvn package -DskipTests)

    mapfile -t artifacts < <(find "$dir" -type f -path '*/target/*.omod' -print)
    if (("${#artifacts[@]}" == 0)); then
      echo "ERROR: Maven completed but no .omod artifact was found for $module." >&2
      return 1
    fi
    for artifact in "${artifacts[@]}"; do
      cp -f "$artifact" openmrs/custom_modules/
      echo "Installed: openmrs/custom_modules/$(basename "$artifact")"
      ((built+=1))
    done
  done

  echo
  echo "Custom module build complete: $built OMOD artifact(s) copied; $missing module source folder(s) skipped."
  echo "Next step: choose 'Build OpenMRS backend' so the Docker image includes these OMODs."
}

build_backend() {
  require_service openmrs-backend
  check_omods
  if [[ "$(service_has_build openmrs-backend)" == "yes" ]]; then
    echo "Building OpenMRS backend using $COMPOSE_FILE ..."
    openmrs_compose build openmrs-backend
  else
    echo "This Compose file uses a prebuilt OpenMRS backend image; pulling it instead of running a build."
    openmrs_compose pull openmrs-backend
  fi
}

start_database() {
  require_service openmrs-db
  echo "Starting the OpenMRS MySQL database (Compose healthcheck/dependency is authoritative)..."
  openmrs_compose up -d openmrs-db
  openmrs_compose ps openmrs-db
}

start_backend() {
  require_service openmrs-backend
  require_service openmrs-db
  check_omods
  echo "Starting OpenMRS backend. Compose waits for openmrs-db to become healthy."
  if [[ "$(service_has_build openmrs-backend)" == "yes" ]]; then
    openmrs_compose up --build -d openmrs-backend
  else
    openmrs_compose up -d openmrs-backend
  fi
  echo "Backend startup can take 15–25 minutes while OpenMRS loads modules and Initializer metadata."
  echo "Follow progress with: $0 logs"
}

start_frontend() {
  require_service openmrs-frontend
  require_service openmrs-backend
  echo "Starting the OpenMRS frontend; Compose waits for backend health."
  # The standard compose definition uses a prebuilt frontend image (no build:).
  # 'up' pulls the image if needed; this avoids a failing 'compose build' call.
  openmrs_compose up -d openmrs-frontend
}

start_openmrs() {
  require_service openmrs-db
  require_service openmrs-backend
  require_service openmrs-frontend
  check_omods
  echo "Starting OpenMRS database, backend and frontend in dependency order."
  if [[ "$(service_has_build openmrs-backend)" == "yes" ]]; then
    openmrs_compose up --build -d openmrs-frontend
  else
    openmrs_compose up -d openmrs-frontend
  fi
  openmrs_compose ps openmrs-db openmrs-backend openmrs-frontend
}

pull_openmrs_images() {
  local services=()
  for service in openmrs-db openmrs-backend openmrs-frontend; do
    if compose config --services | grep -Fxq "$service"; then
      services+=("$service")
    fi
  done
  (("${#services[@]}" > 0)) || { echo "No OpenMRS services found."; return 1; }
  openmrs_compose pull "${services[@]}"
}

show_status() {
  openmrs_compose ps
  echo
  echo "Container health:"
  for name in nidan-openmrs-db nidan-openmrs-backend nidan-openmrs-frontend; do
    if docker inspect "$name" >/dev/null 2>&1; then
      docker inspect -f '{{.Name}}  status={{.State.Status}}  health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$name"
    fi
  done
}

show_logs() {
  local service="${1:-openmrs-backend}"
  require_service "$service"
  openmrs_compose logs --tail=250 --follow "$service"
}

run_diagnostic() {
  require_service openmrs-backend
  local cid
  cid="$(openmrs_compose ps -q openmrs-backend)"
  if [[ -z "$cid" ]]; then
    echo "OpenMRS backend container is not created. Start it first." >&2
    return 1
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]]; then
    echo "OpenMRS backend container is not running. Check logs first." >&2
    return 1
  fi
  if docker exec "$cid" test -x /openmrs/check-initializer.sh; then
    docker exec -it "$cid" /openmrs/check-initializer.sh
  else
    echo "Diagnostic script is absent in this image. Rebuild openmrs-backend to include it." >&2
    return 1
  fi
}

restart_openmrs() {
  local service="${1:-openmrs-backend}"
  require_service "$service"
  openmrs_compose restart "$service"
}

menu() {
  while true; do
    cat <<'MENU'

NIDAN OPENMRS OPERATIONS
  1) Build OpenMRS backend
  2) Build custom OMODs from ../openmrs-backend
  3) Start OpenMRS database only
  4) Build and start OpenMRS backend (database dependency included)
  5) Start OpenMRS frontend
  6) Start complete OpenMRS (database + backend + frontend)
  7) Pull OpenMRS images
  8) Show OpenMRS status/health
  9) Follow OpenMRS backend logs
 10) Follow OpenMRS frontend logs
 11) Run Initializer/configuration diagnostic
 12) Restart OpenMRS backend
 13) Restart OpenMRS frontend
 14) Exit
MENU
    read -r -p "Select [1-14]: " choice
    case "$choice" in
      1) build_backend ;;
      2) build_custom_modules ;;
      3) start_database ;;
      4) start_backend ;;
      5) start_frontend ;;
      6) start_openmrs ;;
      7) pull_openmrs_images ;;
      8) show_status ;;
      9) show_logs openmrs-backend ;;
      10) show_logs openmrs-frontend ;;
      11) run_diagnostic ;;
      12) restart_openmrs openmrs-backend ;;
      13) restart_openmrs openmrs-frontend ;;
      14) return 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

case "${1:-menu}" in
  menu) menu ;;
  build) build_backend ;;
  custom-modules|build-modules) build_custom_modules ;;
  db) start_database ;;
  backend|start-backend) start_backend ;;
  frontend|start-frontend) start_frontend ;;
  start|up) start_openmrs ;;
  pull) pull_openmrs_images ;;
  status|ps) show_status ;;
  logs) show_logs "${2:-openmrs-backend}" ;;
  diagnose|diagnostic) run_diagnostic ;;
  restart) restart_openmrs "${2:-openmrs-backend}" ;;
  *)
    echo "Usage: $0 [--dev] {menu|build|db|backend|frontend|start|pull|status|logs [service]|diagnose|restart [service]}" >&2
    exit 2
    ;;
esac
