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
            raw = base64.b64decode(self.file)
            text = raw.decode("utf-8-sig")
        except (ValueError, UnicodeDecodeError) as exc:
            raise UserError(_("The CSV must be a valid UTF-8 file.")) from exc

        reader = csv.reader(io.StringIO(text, newline=""))
        Area = self.env["uganda.address.area"].sudo()
        created = reused = skipped = 0
        seen = set()
        errors = []

        for line_number, row in enumerate(reader, start=1):
            if not row or not any((cell or "").strip() for cell in row):
                continue
            if len(row) != 6:
                skipped += 1
                errors.append(_("Line %(line)s: expected 6 columns, found %(count)s")
                              % {"line": line_number, "count": len(row)})
                continue

            country, district, county, subcounty, parish, village = [
                (cell or "").strip() for cell in row
            ]
            if country.casefold() != "uganda":
                skipped += 1
                continue
            if not all((country, district, county, subcounty, parish, village)):
                skipped += 1
                errors.append(_("Line %s: one or more hierarchy values are empty.") % line_number)
                continue

            key = tuple(value.casefold() for value in (
                country, district, county, subcounty, parish, village
            ))
            if key in seen:
                skipped += 1
                continue
            seen.add(key)

            parent = None
            try:
                for name, level in (
                    (country, "country"),
                    (district, "district"),
                    (county, "county"),
                    (subcounty, "subcounty"),
                    (parish, "parish"),
                    (village, "village"),
                ):
                    existing = Area.with_context(active_test=False).search(
                        [
                            ("name", "=", name),
                            ("level", "=", level),
                            ("parent_id", "=", parent.id if parent else False),
                        ],
                        limit=1,
                    )
                    if existing:
                        if self.update_existing and not existing.active:
                            existing.active = True
                        parent = existing
                        reused += 1
                    else:
                        parent = Area.create({
                            "name": name,
                            "level": level,
                            "parent_id": parent.id if parent else False,
                        })
                        created += 1
            except Exception as exc:
                skipped += 1
                errors.append(_("Line %(line)s: %(error)s") % {
                    "line": line_number, "error": str(exc)
                })
                _logger.exception("Failed importing Uganda address CSV line %s", line_number)

        message = _(
            "Import completed. Created %(created)s administrative areas; "
            "reused %(reused)s existing areas; skipped %(skipped)s CSV rows."
        ) % {"created": created, "reused": reused, "skipped": skipped}
        if errors:
            message += "\n\n" + _("First import warnings:") + "\n" + "\n".join(errors[:20])
            if len(errors) > 20:
                message += "\n" + _("...and %(count)s more.") % {"count": len(errors) - 20}

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
