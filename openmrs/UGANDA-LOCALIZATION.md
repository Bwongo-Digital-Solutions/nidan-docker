# UgandaEMR content and Uganda regional defaults

The OpenMRS backend build imports the Initializer configuration from
[METS-Programme/openmrs-content-ugandaemrcorepack](https://github.com/METS-Programme/openmrs-content-ugandaemrcorepack).
The source ref is pinned in both backend Dockerfiles so an upstream change cannot
silently alter a production build. Update `UGANDA_CONTENT_REPO_REF` deliberately
when adopting a newer package revision.

## What is included

- Uganda address hierarchy configuration.
- UgandaEMR Initializer backend metadata, including the package's HMIS/Ampath forms,
  location data, provider/attribute metadata, and HIE sync-profile definitions.
- The package's shared address-hierarchy configuration.
- Nidan defaults for English (UK) locale, day-first dates, and the Gregorian calendar.

The repository's `content.properties` currently declares no OMOD or frontend-module
dependencies. This integration therefore imports its configuration files; it does
not install the separate UgandaEMR backend OMOD or UgandaEMR-specific O3 frontend
applications. DHIS2/HMIS connectivity also remains a separate deployment integration:
configure the endpoint, credentials, and organisation unit for the facility's
authorised national service. No Nepal HMIS endpoint is supplied by the template.

## Uganda regional defaults

- OpenMRS JVM/container timezone: `Africa/Kampala` (override with
  `OPENMRS_TIMEZONE`).
- OpenELIS container timezone: `Africa/Kampala` (override with `OPENELIS_TZ`).
- O3 fallback locale: `en-GB`.
- O3 preferred calendar: `gregory`.
- O3 preferred date locale: `en-GB`.
- OpenMRS default locale: `en_GB`.
- HTML Form Entry and legacy UI date formats: `dd/MM/yyyy`.

The O3 date locale is a locale-based display preference. Some third-party or
custom forms may have their own date-format settings and should be checked
separately during clinical acceptance testing.

## Build and rollout

From the Nidan Docker repository root:

```bash
docker compose --profile nidanehr-standard build openmrs-backend openmrs-frontend
```

Back up the OpenMRS database and `openmrs-data` volume before deploying this
change to an existing installation. The Uganda address hierarchy and metadata
are loaded by Initializer at backend startup; this is not a database reset.
Validate patient registration/address entry, existing patient addresses, HMIS
forms, provider/location selection, and report dates before production rollout.

The normal service startup order remains database first, then OpenMRS backend,
then the O3 frontend. Other Nidan services can be started after their declared
dependencies are healthy.
