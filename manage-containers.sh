#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v docker >/dev/null 2>&1; then
    printf 'Error: Docker is not installed or is not on PATH.\n' >&2
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_COMMAND=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_COMMAND=(docker-compose)
else
    printf 'Error: Docker Compose is unavailable. Install the Docker Compose plugin or docker-compose.\n' >&2
    exit 1
fi

if [[ ! -f .env ]]; then
    printf 'Error: .env was not found. Create it from env.template before continuing:\n  cp env.template .env\n' >&2
    exit 1
fi

printf 'Select the Compose stack:\n'
printf '  1) Standard stack (docker-compose.yml)\n'
printf '  2) Development stack (dev.docker-compose.yml)\n'
read -r -p 'Choice [1-2]: ' stack_choice

case "$stack_choice" in
    1) compose_file="docker-compose.yml" ;;
    2) compose_file="dev.docker-compose.yml" ;;
    *)
        printf 'Invalid stack choice: %s\n' "$stack_choice" >&2
        exit 2
        ;;
esac

compose() {
    "${COMPOSE_COMMAND[@]}" -f "$compose_file" "$@"
}

# The standard compose file assigns optional services to profiles. Compose only
# includes the unprofiled services by default, so stack-wide actions must opt in
# to every profile. This is harmless for the development file, which has none.
compose_all_profiles() {
    compose --profile '*' "$@"
}

load_services() {
    local service_line service_name build_context image_reference profiles services_output
    service_names=()
    service_buildable=()
    service_images=()
    service_profiles=()
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'Error: python3 is required to read Compose service definitions.\n' >&2
        return 1
    fi

    if ! services_output="$(
        compose config --format json |
            python3 -c 'import json, sys; services = json.load(sys.stdin).get("services", {}); [print("{}\t{}\t{}\t{}".format(name, "yes" if config.get("build") else "no", config.get("image", ""), ",".join(config.get("profiles", [])))) for name, config in services.items()]'
    )"; then
        printf 'Error: could not read Compose service definitions.\n' >&2
        return 1
    fi

    if [[ -z "$services_output" ]]; then
        printf 'No services were found in %s.\n' "$compose_file"
        return 1
    fi

    while IFS= read -r service_line; do
        IFS=$'\t' read -r service_name build_context image_reference profiles <<< "$service_line"
        service_names+=("$service_name")
        service_buildable+=("$build_context")
        service_images+=("$image_reference")
        service_profiles+=("$profiles")
    done <<< "$services_output"
}

show_services() {
    local index status
    if ! load_services; then
        return 1
    fi

    printf '\nServices in %s:\n' "$compose_file"
    for index in "${!service_names[@]}"; do
        if [[ "${service_buildable[$index]}" == "yes" ]]; then
            status="local build"
        elif [[ -n "${service_images[$index]}" ]]; then
            status="prebuilt image: ${service_images[$index]}"
        else
            status="no local build or image specified"
        fi
        printf '  %s - %s' "${service_names[$index]}" "$status"
        [[ -n "${service_profiles[$index]}" ]] && printf ' [profiles: %s]' "${service_profiles[$index]}"
        printf '\n'
    done
}

select_services() {
    local operation="$1"
    local selection service index eligible_count
    local -a eligible_services=()
    local -a service_choices=()
    selected_services=()

    if ! load_services; then
        return 1
    fi

    for index in "${!service_names[@]}"; do
        if [[ "$operation" == "build" && "${service_buildable[$index]}" == "yes" ]]; then
            eligible_services+=("$index")
        elif [[ "$operation" == "pull" && -n "${service_images[$index]}" ]]; then
            eligible_services+=("$index")
        elif [[ "$operation" == "start" || "$operation" == "manage" ]]; then
            eligible_services+=("$index")
        fi
    done

    eligible_count="${#eligible_services[@]}"
    if ((eligible_count == 0)); then
        printf 'No eligible services found in %s.\n' "$compose_file"
        return 1
    fi

    case "$operation" in
        build) printf '\nServices with local build definitions in %s:\n' "$compose_file" ;;
        pull) printf '\nServices with images in %s:\n' "$compose_file" ;;
        start) printf '\nSelect services to start (local builds and prebuilt images) in %s:\n' "$compose_file" ;;
        *) printf '\nSelect services in %s:\n' "$compose_file" ;;
    esac

    for index in "${!eligible_services[@]}"; do
        service="${eligible_services[$index]}"
        if [[ "$operation" == "pull" ]]; then
            printf '  %d) %s (%s)\n' "$((index + 1))" "${service_names[$service]}" "${service_images[$service]}"
        else
            printf '  %d) %s\n' "$((index + 1))" "${service_names[$service]}"
        fi
    done

    printf 'Enter one or more service numbers separated by spaces or commas (q to cancel).\n'
    read -r -p 'Services: ' selection
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        printf 'Operation cancelled.\n'
        return 1
    fi

    selection="${selection//,/ }"
    read -r -a service_choices <<< "$selection"
    for service in "${service_choices[@]}"; do
        if [[ ! "$service" =~ ^[0-9]+$ ]]; then
            printf 'Invalid service number: %s\n' "$service" >&2
            return 1
        fi
        index=$((10#$service - 1))
        if ((index < 0 || index >= eligible_count)); then
            printf 'Service number out of range: %s\n' "$service" >&2
            return 1
        fi
        service="${service_names[${eligible_services[$index]}]}"
        if [[ ! " ${selected_services[*]} " =~ " ${service} " ]]; then
            selected_services+=("$service")
        fi
    done

    if ((${#selected_services[@]} == 0)); then
        return 1
    fi
    printf 'Selected services: %s\n' "${selected_services[*]}"
}

confirm_removal() {
    local answer
    read -r -p "Remove this stack's containers and network? Named data volumes will be kept. [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

start_all_services() {
    if [[ "$compose_file" == "dev.docker-compose.yml" ]]; then
        printf 'Building the development gateway locally before starting the stack.\n'
        compose build gateway
    fi
    compose up -d
}

start_minimum_core_api() {
    local service
    local has_backend=false
    local has_database=false

    if ! load_services; then
        return 1
    fi

    for service in "${service_names[@]}"; do
        [[ "$service" == "openmrs-backend" ]] && has_backend=true
        [[ "$service" == "openmrs-db" ]] && has_database=true
    done

    if [[ "$has_backend" != true || "$has_database" != true ]]; then
        printf 'Error: %s must define both openmrs-backend and openmrs-db for the minimum Core EHR API setup.\n' "$compose_file" >&2
        return 1
    fi

    printf 'Starting the minimum Core EHR API: openmrs-backend and its required openmrs-db dependency.\n'
    printf 'Frontend, gateway, and optional integrations are excluded; already-running services are left unchanged.\n'
    compose up --build -d openmrs-backend
}

sync_frontend_static_files() {
    bash "$SCRIPT_DIR/manage-services.sh" static-assets
}

while true; do
    printf '\nSelected stack: %s\n' "$compose_file"
    printf 'Choose an action:\n'
    printf '  1) Build selected services\n'
    printf '  2) Start selected services (build local services when needed; start prebuilt images as-is)\n'
    printf '  3) Pull selected prebuilt images\n'
    printf '  4) Build and start minimum Core EHR API\n'
    printf '  5) Start all services\n'
    printf '  6) Stop all services\n'
    printf '  7) Remove containers\n'
    printf '  8) Show status\n'
    printf '  9) List all services and image sources\n'
    printf '  10) Copy frontend static files without rebuilding\n'
    printf '  11) Restart selected services\n'
    printf '  12) Stop selected services\n'
    printf '  13) Show logs for selected services\n'
    printf '  14) OpenMRS and service-specific operations\n'
    printf '  15) Exit\n'
    read -r -p 'Choice [1-15]: ' action

    case "$action" in
        1)
            if select_services build; then
                compose build "${selected_services[@]}"
            fi
            ;;
        2)
            if select_services start; then
                compose_all_profiles up --build -d "${selected_services[@]}"
            fi
            ;;
        3)
            if select_services pull; then
                compose pull "${selected_services[@]}"
            fi
            ;;
        4)
            if start_minimum_core_api; then
                :
            fi
            ;;
        5)
            if [[ "$compose_file" == "dev.docker-compose.yml" ]]; then
                start_all_services
            else
                printf 'Starting all services, including services assigned to optional Compose profiles.\n'
                compose_all_profiles up -d
            fi
            ;;
        6)
            compose_all_profiles stop
            ;;
        7)
            if confirm_removal; then
                compose_all_profiles down
            else
                printf 'Removal cancelled.\n'
            fi
            ;;
        8)
            compose_all_profiles ps
            ;;
        9)
            show_services
            ;;
        10)
            sync_frontend_static_files
            ;;
        11)
            if select_services manage; then
                compose restart "${selected_services[@]}"
            fi
            ;;
        12)
            if select_services manage; then
                compose stop "${selected_services[@]}"
            fi
            ;;
        13)
            if select_services manage; then
                compose logs --tail=200 --follow "${selected_services[@]}"
            fi
            ;;
        14)
            if [[ "$compose_file" == "dev.docker-compose.yml" ]]; then
                bash manage-services.sh --dev
            else
                bash manage-services.sh
            fi
            ;;
        15)
            exit 0
            ;;
        *)
            printf 'Invalid action: %s\n' "$action" >&2
            ;;
    esac
done
