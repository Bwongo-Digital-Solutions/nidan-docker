from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class UgandaAddressArea(models.Model):
    _name = "uganda.address.area"
    _description = "Uganda Administrative Area"
    _parent_name = "parent_id"
    _parent_store = True
    _order = "level, name"

    name = fields.Char(required=True, index=True)
    code = fields.Char(index=True, copy=False, help="Official government administrative code, where available.")
    level = fields.Selection([
        ("country", "Country"),
        ("region", "Region"),
        ("district", "District"),
        ("city", "City"),
        ("county", "County"),
        ("city_division", "City Division"),
        ("municipality", "Municipality"),
        ("subcounty", "Sub-county"),
        ("town_council", "Town Council"),
        ("municipal_division", "Municipal Division"),
        ("parish", "Parish"),
        ("ward", "Ward"),
        ("village", "Village"),
        ("zone", "Zone / Cell"),
    ], required=True, index=True)
    parent_id = fields.Many2one(
        "uganda.address.area", string="Parent Area",
        index=True, ondelete="restrict",
    )
    parent_path = fields.Char(index=True)
    child_ids = fields.One2many("uganda.address.area", "parent_id", string="Child Areas")
    complete_name = fields.Char(compute="_compute_complete_name", store=True, index=True)
    active = fields.Boolean(default=True)

    _sql_constraints = [
        (
            "uganda_area_parent_level_check",
            "CHECK ((level = 'country' AND parent_id IS NULL) OR "
            "(level != 'country' AND parent_id IS NOT NULL))",
            "Only the country may be a root administrative area.",
        ),
    ]

    # Multiple parent types are intentional: Uganda has distinct rural and
    # urban local-government structures; they must not be forced into one chain.
    _ALLOWED_PARENTS = {
        "country": (),
        "region": ("country",),
        "district": ("country", "region"),  # country keeps legacy CSV imports valid
        "city": ("region", "district"),
        "county": ("district",),
        "city_division": ("city",),
        "municipality": ("district",),
        "subcounty": ("county", "district"),
        "town_council": ("district",),
        "municipal_division": ("municipality",),
        "parish": ("subcounty", "town_council", "municipal_division", "city_division"),
        "ward": ("town_council", "municipal_division", "city_division"),
        "village": ("parish",),
        "zone": ("ward",),
    }

    @api.depends("name", "parent_id.complete_name")
    def _compute_complete_name(self):
        for area in self:
            area.complete_name = (
                "%s / %s" % (area.parent_id.complete_name, area.name)
                if area.parent_id else area.name
            )

    @api.constrains("level", "parent_id")
    def _check_parent_level(self):
        for area in self:
            allowed = self._ALLOWED_PARENTS.get(area.level, ())
            if area.level == "country":
                if area.parent_id:
                    raise ValidationError(_("A country cannot have a parent area."))
                continue
            if not area.parent_id or area.parent_id.level not in allowed:
                raise ValidationError(
                    _("The selected parent is not valid for the %(level)s level.")
                    % {"level": area.level}
                )
            if area.parent_id == area or area.parent_id.parent_path and (
                area.parent_path and area.parent_path.startswith(area.parent_id.parent_path)
            ):
                raise ValidationError(_("An administrative area cannot be its own ancestor."))

    @api.constrains("name", "level", "parent_id")
    def _check_duplicate_area(self):
        for area in self:
            domain = [
                ("id", "!=", area.id),
                ("level", "=", area.level),
                ("parent_id", "=", area.parent_id.id or False),
                ("name", "=ilike", area.name.strip()),
            ]
            if self.search_count(domain):
                raise ValidationError(
                    _("An area with this name and administrative parent already exists.")
                )
