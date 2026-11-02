# Uganda Address Hierarchy (Odoo 19)

Adds the Uganda administrative address hierarchy to Odoo Contacts:

**Country → District → County → Subcounty → Parish → Village**

## Installation

1. Place this directory in an Odoo addons path.
2. Restart Odoo and update the Apps list.
3. Install **Uganda Address Hierarchy**.
4. As an Odoo administrator, open **Contacts → Uganda Addresses → Import CSV**.
5. Select the supplied addresshierarchy.csv and run the import.

The import is safe to repeat: matching areas are reused, inactive matches can be reactivated, and non-Uganda rows are ignored. Invalid rows are reported rather than guessed. Existing contacts and address fields are not wiped or rewritten.

The contact form adds cascading District, County, Subcounty, Parish and Village selectors. Changing a parent clears child selections that no longer belong to it.

## CSV source format

The importer expects six columns, no header row, in this order:

1. Country
2. District (OpenMRS field COUNTY_DISTRICT)
3. County (STATE_PROVINCE)
4. Subcounty (ADDRESS_3)
5. Parish (ADDRESS_4)
6. Village (ADDRESS_5)

Quoted CSV values, including commas inside a field, are handled by Python's CSV parser.
