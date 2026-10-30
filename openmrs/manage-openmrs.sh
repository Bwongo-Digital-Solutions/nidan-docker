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

build_backend() {
  require_service openmrs-backend
  check_omods
  echo "Building OpenMRS backend using $COMPOSE_FILE ..."
  openmrs_compose build openmrs-backend
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
  echo "Building and starting OpenMRS backend. Compose waits for openmrs-db to become healthy."
  openmrs_compose up --build -d openmrs-backend
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
  openmrs_compose up --build -d openmrs-frontend
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
  2) Start OpenMRS database only
  3) Build and start OpenMRS backend (database dependency included)
  4) Start OpenMRS frontend
  5) Start complete OpenMRS (database + backend + frontend)
  6) Pull OpenMRS images
  7) Show OpenMRS status/health
  8) Follow OpenMRS backend logs
  9) Follow OpenMRS frontend logs
 10) Run Initializer/configuration diagnostic
 11) Restart OpenMRS backend
 12) Restart OpenMRS frontend
 13) Exit
MENU
    read -r -p "Select [1-13]: " choice
    case "$choice" in
      1) build_backend ;;
      2) start_database ;;
      3) start_backend ;;
      4) start_frontend ;;
      5) start_openmrs ;;
      6) pull_openmrs_images ;;
      7) show_status ;;
      8) show_logs openmrs-backend ;;
      9) show_logs openmrs-frontend ;;
      10) run_diagnostic ;;
      11) restart_openmrs openmrs-backend ;;
      12) restart_openmrs openmrs-frontend ;;
      13) return 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

case "${1:-menu}" in
  menu) menu ;;
  build) build_backend ;;
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
