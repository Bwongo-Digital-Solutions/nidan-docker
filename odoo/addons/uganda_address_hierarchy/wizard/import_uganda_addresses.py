import base64
import csv
import io
import logging

from odoo import fields, models, _
from odoo.exceptions import UserError

_logger = logging.getLogger(__name__)


class UgandaAddressImportWizard(models.TransientModel):
    _name = "uganda.address.import.wizard"
    _description = "Import Uganda Address Hierarchy"

    file = fields.Binary(required=True, string="Address CSV")
    filename = fields.Char(string="Filename")
    update_existing = fields.Boolean(
        string="Reactivate existing areas",
        default=True,
        help="Matching areas are reused; inactive matches can be reactivated.",
    )

    def action_import(self):
        self.ensure_one()
        if not self.file:
            raise UserError(_("Please select the Uganda address CSV file."))

        try:
            text = base64.b64decode(self.file).decode("utf-8-sig")
        except (ValueError, UnicodeDecodeError) as exc:
            raise UserError(_("The CSV must be a valid UTF-8 file.")) from exc

        legacy_levels = ("country", "district", "county", "subcounty", "parish", "village")
        regional_levels = ("country", "region", "district", "county", "subcounty", "parish", "village")
        import_order = (
            "country", "region", "district", "city", "county", "city_division",
            "municipality", "subcounty", "town_council", "municipal_division",
            "parish", "ward", "village", "zone",
        )
        nodes_by_level = {level: {} for level in import_order}
        seen_paths = set()
        skipped = ignored = repaired = 0
        errors = []

        for line_number, row in enumerate(csv.reader(io.StringIO(text, newline="")), 1):
            if not row or not any((cell or "").strip() for cell in row):
                continue
            header = [cell.strip().casefold().replace(" ", "_").replace("/", "_") for cell in row]
            if line_number == 1 and header and header[0] in ("country", "country_name") and any(
                value in header for value in ("region", "city", "municipality", "town_council")
            ):
                continue
            if (row[0] or "").strip().casefold() != "uganda":
                ignored += 1
                continue
            if len(row) == 5 and "," in row[4]:
                row = row[:4] + [part.strip() for part in row[4].split(",", 1)]
                repaired += 1
            if len(row) == 6:
                row_levels = legacy_levels
            elif len(row) == 7:
                row_levels = regional_levels
            else:
                skipped += 1
                errors.append(_("Line %(line)s: expected 6 legacy columns or 7 regional columns, found %(count)s")
                              % {"line": line_number, "count": len(row)})
                continue
            values = tuple((cell or "").strip() for cell in row)
            if not all(values):
                skipped += 1
                errors.append(_("Line %s: one or more hierarchy values are empty.") % line_number)
                continue
            normalized = tuple(value.casefold() for value in values)
            if normalized in seen_paths:
                skipped += 1
                continue
            seen_paths.add(normalized)
            for index, level in enumerate(row_levels):
                parent_key = normalized[:index] or None
                node_key = (parent_key, normalized[index])
                nodes_by_level[level].setdefault(node_key, values[index])

        Area = self.env["uganda.address.area"].sudo().with_context(active_test=False)
        path_to_id = {}
        created = reused = 0

        for level in import_order:
            existing = Area.search([("level", "=", level)])
            existing_by_parent_name = {
                (record.parent_id.id or False, record.name.casefold()): record
                for record in existing
            }
            pending = []
            for (parent_key, normalized_name), name in nodes_by_level[level].items():
                parent_id = path_to_id.get(parent_key) if parent_key else False
                existing_record = existing_by_parent_name.get((parent_id or False, normalized_name))
                full_path_key = (parent_key or ()) + (normalized_name,)
                if existing_record:
                    if self.update_existing and not existing_record.active:
                        existing_record.active = True
                    path_to_id[full_path_key] = existing_record.id
                    reused += 1
                else:
                    pending.append((full_path_key, {
                        "name": name, "level": level, "parent_id": parent_id,
                    }))
            for offset in range(0, len(pending), 1000):
                batch = pending[offset:offset + 1000]
                records = Area.create([values for _key, values in batch])
                for (path_key, _values), record in zip(batch, records):
                    path_to_id[path_key] = record.id
                created += len(records)

        message = _(
            "Import completed. Created %(created)s areas; reused %(reused)s existing areas; "
            "ignored %(ignored)s non-Uganda rows; repaired %(repaired)s five-column rows; "
            "skipped %(skipped)s duplicate or invalid rows."
        ) % {
            "created": created, "reused": reused, "ignored": ignored,
            "repaired": repaired, "skipped": skipped,
        }
        if errors:
            message += "\n\n" + _("Import warnings:") + "\n" + "\n".join(errors[:20])
            if len(errors) > 20:
                message += "\n" + _("...and %(count)s more.") % {"count": len(errors) - 20}

        _logger.info(
            "Uganda address import finished: %s created, %s reused, %s ignored, %s skipped",
            created, reused, ignored, skipped,
        )
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": _("Uganda Address Import"),
                "message": message,
                "type": "warning" if errors else "success",
                "sticky": bool(errors),
                "next": {"type": "ir.actions.act_window_close"},
            },
        }
