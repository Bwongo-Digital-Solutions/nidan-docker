# Uganda Address Hierarchy (Odoo 19)

Uganda-specific administrative addresses for Odoo Contacts and the NidanEHR ecosystem. The module supports both rural and urban local-government structures; it does not impose one Nepal-style linear hierarchy on every Ugandan address.

## Supported administrative levels

- Country and four geographical regions: Central, Eastern, Northern and Western.
- Districts and cities.
- Rural: county, sub-county, parish and village.
- Urban: city division, municipality, municipal division, town council, ward and zone/cell.

The allowed parent relationships are validated by the model. Examples include District → County → Sub-county → Parish → Village and City → City Division → Ward → Zone. Municipalities and town councils are represented as distinct local-government branches. Not every address must populate every level.

## Contact addresses

The contact form provides cascading rural and urban selectors, a landmark field and optional GPS latitude/longitude. Changing an upper-level selection clears dependent selections. Address fields are optional so incomplete or informal addresses can still be captured.

## Installation

1. Ensure this directory is included in the Odoo addons path.
2. Restart Odoo and update the Apps list.
3. Install Uganda Address Hierarchy.
4. Open Contacts → Uganda Addresses to manage administrative areas or import a CSV.

No Nepal localization or Nepal-specific dependency is required.

## CSV import

The importer accepts the original six-column rural format, preserving compatibility:

1. Country (Uganda)
2. District
3. County
4. Sub-county
5. Parish
6. Village

It also accepts a seven-column regional rural format:

1. Country (Uganda)
2. Region
3. District
4. County
5. Sub-county
6. Parish
7. Village

Rows for other countries are ignored. Matching areas are reused, inactive matches can be reactivated, and duplicate paths are skipped. The importer does not invent missing administrative units.

Urban administrative units can be maintained through Contacts → Uganda Addresses → Administrative Areas. Add each record under its valid parent; the model enforces the allowed Uganda parent/child relationships.

## Data governance

Use current administrative-unit registers and boundary datasets published by UBOS and the Ministry of Local Government. Do not treat historical totals as permanent limits: districts, cities and lower local-government units can change. Store official codes in the code field when the source provides them. Import data only from an authoritative, dated source and retain that source/version with the import file.

## Interoperability

The generic uganda.address.area model gives NidanEHR components a common administrative-area record. Integrations with OpenMRS and OpenELIS should exchange stable area IDs/codes rather than relying on free-text names. GPS coordinates are optional and belong to the contact record.

## Security

Internal users have read-only access to administrative areas. System administrators can create, update, deactivate and import records. Administrative data should be maintained by authorized administrators.
