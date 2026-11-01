# UgandaEMR content and Uganda regional defaults

The Nidan OpenMRS backend imports the Initializer configuration from
[METS-Programme/openmrs-content-ugandaemrcorepack](https://github.com/METS-Programme/openmrs-content-ugandaemrcorepack).
The build pins the verified upstream commit
`58f29646675dbeb3db2dbd1bc50f7cf3a6c1d36c`. The Dockerfiles fetch that commit
explicitly and check it out detached; they do not pass a commit SHA to
`git clone --branch` (that option accepts branch and tag names, not raw commit SHAs).

## What the Uganda country profile includes

- Uganda address hierarchy configuration.
- UgandaEMR Initializer backend metadata, including HMIS/Ampath forms,
  location data, provider/attribute metadata, and HIE sync-profile definitions.
- The package's shared address-hierarchy configuration.
- Nidan defaults for English (UK) locale, day-first dates, and the Gregorian calendar.
- OpenMRS JVM/container timezone `Africa/Kampala` (override with
  `OPENMRS_TIMEZONE`).
- OpenELIS container timezone `Africa/Kampala` (override with `OPENELIS_TZ`).
- O3 fallback and preferred date locale `en-GB`, preferred calendar `gregory`.
- OpenMRS default locale `en_GB`.
- HTML Form Entry and legacy UI date formats `dd/MM/yyyy`.

The Nidan defaults are stored in
`openmrs/configuration/backend_configuration/globalproperties/nidan-uganda-defaults.xml`
and are copied into the backend image alongside the UgandaEMR package configuration.
Initializer applies these settings at backend startup.

The package's `content.properties` currently declares no OMOD or frontend-module
dependencies. This integration imports its configuration files; it does not install
the separate UgandaEMR backend OMOD or UgandaEMR-specific O3 frontend applications.
DHIS2/HMIS connectivity remains a separate deployment integration: configure the
endpoint, credentials, and organisation unit for the facility's authorised national
service.

## Nepal profile status

The Nepal-specific calendar archive in `openmrs/frontend/packages` is not referenced
by `spa-assemble-config.json`, and therefore is not installed into the SPA. The active
SPA configuration uses the Gregorian calendar and `en-GB` locale. No Nepal HMIS
endpoint or Nepal country-profile configuration is enabled by this setup.

## Build and use

### Standard stack

From the Nidan Docker repository root:

```bash
# Build the backend with UgandaEMR content and Uganda regional defaults
docker compose --profile nidanehr-standard build openmrs-backend

# Start/recreate the backend after backing up the OpenMRS database and data volume
docker compose --profile nidanehr-standard up -d openmrs-backend

# Follow startup and Initializer import logs
docker compose logs -f openmrs-backend
```

### Development stack

The default `dev.docker-compose.yml` uses the upstream OpenMRS QA backend image.
To use the Uganda country profile in development, combine it with the supplied
override:

```bash
docker compose \
  -f dev.docker-compose.yml \
  -f dev.uganda.docker-compose.yml \
  up -d --build
```

The override builds the Nidan backend from `openmrs/Dockerfile`, supplies the
MySQL connection settings, and sets the timezone to `Africa/Kampala`.

### Verify after startup

1. Open the OpenMRS UI and check that the default locale is English (UK).
2. Open patient registration and verify that the address hierarchy offers Uganda
   regions/districts/sub-counties from the UgandaEMR configuration.
3. Check that date fields display day/month/year where the relevant form supports
   the configured date format.
4. Check the OpenMRS container timezone with
   `docker exec nidan-openmrs-backend date` (should show East Africa Time).
5. Review `docker compose logs openmrs-backend` for successful Initializer import
   and resolve any configuration errors before clinical use.

Back up the OpenMRS database and `openmrs-data` volume before deploying this change
to an existing installation. This is not a database reset. Validate patient
registration/address entry, existing patient addresses, HMIS forms,
provider/location selection, and report dates before production rollout.

The UgandaEMR content package is not a substitute for clinical acceptance testing.
Some third-party or custom forms may have their own date-format settings and should
be checked separately.
