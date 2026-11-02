from odoo import api, fields, models, _
from odoo.exceptions import ValidationError


class ResPartner(models.Model):
    _inherit = "res.partner"

    uganda_district_id = fields.Many2one(
        "uganda.address.area", string="District",
        domain="[('level', '=', 'district')]",
        ondelete="restrict",
    )
    uganda_county_id = fields.Many2one(
        "uganda.address.area", string="County",
        domain="[('level', '=', 'county'), ('parent_id', '=', uganda_district_id)]",
        ondelete="restrict",
    )
    uganda_subcounty_id = fields.Many2one(
        "uganda.address.area", string="Subcounty",
        domain="[('level', '=', 'subcounty'), ('parent_id', '=', uganda_county_id)]",
        ondelete="restrict",
    )
    uganda_parish_id = fields.Many2one(
        "uganda.address.area", string="Parish",
        domain="[('level', '=', 'parish'), ('parent_id', '=', uganda_subcounty_id)]",
        ondelete="restrict",
    )
    uganda_village_id = fields.Many2one(
        "uganda.address.area", string="Village",
        domain="[('level', '=', 'village'), ('parent_id', '=', uganda_parish_id)]",
        ondelete="restrict",
    )

    @api.onchange("uganda_district_id")
    def _onchange_uganda_district_id(self):
        if self.uganda_district_id:
            uganda = self.env["res.country"].search([("code", "=", "UG")], limit=1)
            if uganda:
                self.country_id = uganda
        self.uganda_county_id = False
        self.uganda_subcounty_id = False
        self.uganda_parish_id = False
        self.uganda_village_id = False

    @api.onchange("uganda_county_id")
    def _onchange_uganda_county_id(self):
        self.uganda_subcounty_id = False
        self.uganda_parish_id = False
        self.uganda_village_id = False

    @api.onchange("uganda_subcounty_id")
    def _onchange_uganda_subcounty_id(self):
        self.uganda_parish_id = False
        self.uganda_village_id = False

    @api.onchange("uganda_parish_id")
    def _onchange_uganda_parish_id(self):
        self.uganda_village_id = False

    @api.constrains(
        "uganda_district_id", "uganda_county_id", "uganda_subcounty_id",
        "uganda_parish_id", "uganda_village_id",
    )
    def _check_uganda_address_hierarchy(self):
        for partner in self:
            chain = (
                (partner.uganda_county_id, partner.uganda_district_id, "district"),
                (partner.uganda_subcounty_id, partner.uganda_county_id, "county"),
                (partner.uganda_parish_id, partner.uganda_subcounty_id, "subcounty"),
                (partner.uganda_village_id, partner.uganda_parish_id, "parish"),
            )
            if partner.uganda_district_id and partner.uganda_district_id.level != "district":
                raise ValidationError(_("The selected area is not a district."))
            for child, parent, expected_parent_level in chain:
                if child and (
                    not parent
                    or child.parent_id != parent
                    or parent.level != expected_parent_level
                ):
                    raise ValidationError(
                        _("Each Uganda address selection must belong to the selected parent area.")
                    )
