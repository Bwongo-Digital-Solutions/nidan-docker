from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class UgandaAddressArea(models.Model):
    _name = "uganda.address.area"
    _description = "Uganda Administrative Area"
    _parent_name = "parent_id"
    _parent_store = True
    _order = "level, name"

    name = fields.Char(required=True, index=True)
    level = fields.Selection(
        [
            ("country", "Country"),
            ("district", "District"),
            ("county", "County"),
            ("subcounty", "Subcounty"),
            ("parish", "Parish"),
            ("village", "Village"),
        ],
        required=True,
        index=True,
    )
    parent_id = fields.Many2one(
        "uganda.address.area", string="Parent Area",
        index=True, ondelete="restrict",
    )
    parent_path = fields.Char(index=True)
    child_ids = fields.One2many("uganda.address.area", "parent_id", string="Child Areas")
    complete_name = fields.Char(compute="_compute_complete_name", store=True)
    active = fields.Boolean(default=True)

    _sql_constraints = [
        (
            "uganda_area_parent_level_check",
            "CHECK ((level = 'country' AND parent_id IS NULL) OR "
            "(level IN ('district', 'county', 'subcounty', 'parish', 'village') "
            "AND parent_id IS NOT NULL))",
            "Only country records may be root areas.",
        ),
    ]

    @api.depends("name", "parent_id.complete_name")
    def _compute_complete_name(self):
        for area in self:
            area.complete_name = (
                "%s / %s" % (area.parent_id.complete_name, area.name)
                if area.parent_id else area.name
            )

    @api.constrains("level", "parent_id")
    def _check_parent_level(self):
        expected_parent = {
            "district": "country",
            "county": "district",
            "subcounty": "county",
            "parish": "subcounty",
            "village": "parish",
        }
        for area in self:
            if area.level == "country" and area.parent_id:
                raise ValidationError(_("A country cannot have a parent area."))
            if area.level != "country":
                expected = expected_parent.get(area.level)
                if not area.parent_id or area.parent_id.level != expected:
                    raise ValidationError(
                        _("The parent of a %(level)s must be a %(parent)s.")
                        % {"level": area.level, "parent": expected}
                    )
