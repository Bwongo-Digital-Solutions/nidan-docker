from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class ResPartner(models.Model):
    _inherit = "res.partner"

    uganda_region_id = fields.Many2one(
        "uganda.address.area", string="Region",
        domain="[('level', '=', 'region')]", ondelete="restrict",
    )
    uganda_district_id = fields.Many2one(
        "uganda.address.area", string="District",
        domain="[('level', '=', 'district'), '|', ('parent_id', '=', uganda_region_id), ('parent_id.level', '=', 'country')]",
        ondelete="restrict",
    )
    uganda_city_id = fields.Many2one(
        "uganda.address.area", string="City",
        domain="[('level', '=', 'city')]", ondelete="restrict",
    )
    uganda_city_division_id = fields.Many2one(
        "uganda.address.area", string="City Division",
        domain="[('level', '=', 'city_division'), ('parent_id', '=', uganda_city_id)]",
        ondelete="restrict",
    )
    uganda_county_id = fields.Many2one(
        "uganda.address.area", string="County",
        domain="[('level', '=', 'county'), ('parent_id', '=', uganda_district_id)]",
        ondelete="restrict",
    )
    uganda_municipality_id = fields.Many2one(
        "uganda.address.area", string="Municipality",
        domain="[('level', '=', 'municipality'), ('parent_id', '=', uganda_district_id)]",
        ondelete="restrict",
    )
    uganda_subcounty_id = fields.Many2one(
        "uganda.address.area", string="Sub-county",
        domain="[('level', '=', 'subcounty'), ('parent_id', '=', uganda_county_id)]",
        ondelete="restrict",
    )
    uganda_town_council_id = fields.Many2one(
        "uganda.address.area", string="Town Council",
        domain="[('level', '=', 'town_council'), ('parent_id', '=', uganda_district_id)]",
        ondelete="restrict",
    )
    uganda_municipal_division_id = fields.Many2one(
        "uganda.address.area", string="Municipal Division",
        domain="[('level', '=', 'municipal_division'), ('parent_id', '=', uganda_municipality_id)]",
        ondelete="restrict",
    )
    uganda_parish_id = fields.Many2one(
        "uganda.address.area", string="Parish",
        domain="[('level', '=', 'parish'), ('parent_id', 'in', [uganda_subcounty_id, uganda_town_council_id, uganda_municipal_division_id, uganda_city_division_id])]",
        ondelete="restrict",
    )
    uganda_ward_id = fields.Many2one(
        "uganda.address.area", string="Ward",
        domain="[('level', '=', 'ward'), ('parent_id', 'in', [uganda_town_council_id, uganda_municipal_division_id, uganda_city_division_id])]",
        ondelete="restrict",
    )
    uganda_village_id = fields.Many2one(
        "uganda.address.area", string="Village",
        domain="[('level', '=', 'village'), ('parent_id', '=', uganda_parish_id)]",
        ondelete="restrict",
    )
    uganda_zone_id = fields.Many2one(
        "uganda.address.area", string="Zone / Cell",
        domain="[('level', '=', 'zone'), ('parent_id', '=', uganda_ward_id)]",
        ondelete="restrict",
    )
    uganda_landmark = fields.Char(string="Landmark")
    uganda_gps_latitude = fields.Float(string="GPS Latitude", digits=(10, 7))
    uganda_gps_longitude = fields.Float(string="GPS Longitude", digits=(10, 7))

    def _clear_uganda_address(self, *field_names):
        for field_name in field_names:
            self[field_name] = False

    @api.onchange("uganda_region_id")
    def _onchange_uganda_region_id(self):
        self._clear_uganda_address(
            "uganda_district_id", "uganda_city_id", "uganda_city_division_id",
            "uganda_county_id", "uganda_municipality_id", "uganda_subcounty_id",
            "uganda_town_council_id", "uganda_municipal_division_id",
            "uganda_parish_id", "uganda_ward_id", "uganda_village_id", "uganda_zone_id",
        )
        if self.uganda_region_id:
            uganda = self.env["res.country"].search([("code", "=", "UG")], limit=1)
            if uganda:
                self.country_id = uganda

    @api.onchange("uganda_district_id")
    def _onchange_uganda_district_id(self):
        self._clear_uganda_address(
            "uganda_county_id", "uganda_municipality_id", "uganda_subcounty_id",
            "uganda_town_council_id", "uganda_municipal_division_id",
            "uganda_parish_id", "uganda_ward_id", "uganda_village_id", "uganda_zone_id",
        )
        if self.uganda_district_id:
            uganda = self.env["res.country"].search([("code", "=", "UG")], limit=1)
            if uganda:
                self.country_id = uganda
            if self.uganda_region_id and self.uganda_district_id.parent_id.level == "region" and self.uganda_district_id.parent_id != self.uganda_region_id:
                self.uganda_district_id = False

    @api.onchange("uganda_city_id")
    def _onchange_uganda_city_id(self):
        self._clear_uganda_address("uganda_city_division_id", "uganda_parish_id", "uganda_ward_id", "uganda_village_id", "uganda_zone_id")
        if self.uganda_city_id:
            uganda = self.env["res.country"].search([("code", "=", "UG")], limit=1)
            if uganda:
                self.country_id = uganda

    @api.onchange("uganda_city_division_id", "uganda_municipality_id", "uganda_town_council_id")
    def _onchange_uganda_urban_parent_id(self):
        self._clear_uganda_address("uganda_municipal_division_id", "uganda_parish_id", "uganda_ward_id", "uganda_village_id", "uganda_zone_id")

    @api.onchange("uganda_county_id")
    def _onchange_uganda_county_id(self):
        self._clear_uganda_address("uganda_subcounty_id", "uganda_parish_id", "uganda_village_id")

    @api.onchange("uganda_subcounty_id", "uganda_municipal_division_id", "uganda_town_council_id")
    def _onchange_uganda_parish_parent_id(self):
        self._clear_uganda_address("uganda_parish_id", "uganda_village_id")

    @api.onchange("uganda_parish_id")
    def _onchange_uganda_parish_id(self):
        self.uganda_village_id = False

    @api.onchange("uganda_ward_id")
    def _onchange_uganda_ward_id(self):
        self.uganda_zone_id = False

    @api.constrains(
        "uganda_region_id", "uganda_district_id", "uganda_city_id",
        "uganda_city_division_id", "uganda_county_id", "uganda_municipality_id",
        "uganda_subcounty_id", "uganda_town_council_id", "uganda_municipal_division_id",
        "uganda_parish_id", "uganda_ward_id", "uganda_village_id", "uganda_zone_id",
        "uganda_gps_latitude", "uganda_gps_longitude",
    )
    def _check_uganda_address_hierarchy(self):
        for partner in self:
            selections = [
                (partner.uganda_district_id, ("district",)),
                (partner.uganda_region_id, ("region",)),
                (partner.uganda_city_id, ("city",)),
                (partner.uganda_city_division_id, ("city_division",)),
                (partner.uganda_county_id, ("county",)),
                (partner.uganda_municipality_id, ("municipality",)),
                (partner.uganda_subcounty_id, ("subcounty",)),
                (partner.uganda_town_council_id, ("town_council",)),
                (partner.uganda_municipal_division_id, ("municipal_division",)),
                (partner.uganda_parish_id, ("parish",)),
                (partner.uganda_ward_id, ("ward",)),
                (partner.uganda_village_id, ("village",)),
                (partner.uganda_zone_id, ("zone",)),
            ]
            for area, expected_levels in selections:
                if area and area.level not in expected_levels:
                    raise ValidationError(_("One of the selected Uganda address levels is invalid."))

            parent_checks = [
                (partner.uganda_district_id, partner.uganda_region_id, ("region",)),
                (partner.uganda_city_division_id, partner.uganda_city_id, ("city",)),
                (partner.uganda_county_id, partner.uganda_district_id, ("district",)),
                (partner.uganda_municipality_id, partner.uganda_district_id, ("district",)),
                (partner.uganda_subcounty_id, partner.uganda_county_id, ("county",)),
                (partner.uganda_town_council_id, partner.uganda_district_id, ("district",)),
                (partner.uganda_municipal_division_id, partner.uganda_municipality_id, ("municipality",)),
                (partner.uganda_village_id, partner.uganda_parish_id, ("parish",)),
                (partner.uganda_zone_id, partner.uganda_ward_id, ("ward",)),
            ]
            for child, parent, parent_levels in parent_checks:
                if child and child.parent_id.level in parent_levels and parent and child.parent_id != parent:
                    raise ValidationError(_("Each selected address must belong to the selected parent area."))
                if child and parent and child.parent_id != parent:
                    raise ValidationError(_("Each selected address must belong to the selected parent area."))

            if partner.uganda_city_id:
                city_parent = partner.uganda_city_id.parent_id
                if city_parent.level == "region" and partner.uganda_region_id and city_parent != partner.uganda_region_id:
                    raise ValidationError(_("The selected city does not belong to the selected region."))
                if city_parent.level == "district" and partner.uganda_district_id and city_parent != partner.uganda_district_id:
                    raise ValidationError(_("The selected city does not belong to the selected district."))

            parish_parent = partner.uganda_parish_id.parent_id if partner.uganda_parish_id else False
            selected_parish_parents = (
                partner.uganda_subcounty_id, partner.uganda_town_council_id,
                partner.uganda_municipal_division_id, partner.uganda_city_division_id,
            )
            if partner.uganda_parish_id and parish_parent not in selected_parish_parents:
                raise ValidationError(_("The selected parish does not belong to the selected rural or urban area."))

            ward_parent = partner.uganda_ward_id.parent_id if partner.uganda_ward_id else False
            selected_ward_parents = (
                partner.uganda_town_council_id, partner.uganda_municipal_division_id,
                partner.uganda_city_division_id,
            )
            if partner.uganda_ward_id and ward_parent not in selected_ward_parents:
                raise ValidationError(_("The selected ward does not belong to the selected urban division."))

            if partner.uganda_gps_latitude is not False and not -90 <= partner.uganda_gps_latitude <= 90:
                raise ValidationError(_("GPS latitude must be between -90 and 90."))
            if partner.uganda_gps_longitude is not False and not -180 <= partner.uganda_gps_longitude <= 180:
                raise ValidationError(_("GPS longitude must be between -180 and 180."))
            if partner.uganda_region_id or partner.uganda_district_id or partner.uganda_city_id:
                uganda = self.env["res.country"].search([("code", "=", "UG")], limit=1)
                if uganda and partner.country_id and partner.country_id != uganda:
                    raise ValidationError(_("Uganda administrative areas require the country to be Uganda."))
