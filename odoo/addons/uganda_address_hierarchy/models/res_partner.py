from odoo import api, fields, models


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
        for partner in self:
            if partner.uganda_county_id.parent_id != partner.uganda_district_id:
                partner.uganda_county_id = False
                partner.uganda_subcounty_id = False
                partner.uganda_parish_id = False
                partner.uganda_village_id = False

    @api.onchange("uganda_county_id")
    def _onchange_uganda_county_id(self):
        for partner in self:
            if partner.uganda_subcounty_id.parent_id != partner.uganda_county_id:
                partner.uganda_subcounty_id = False
                partner.uganda_parish_id = False
                partner.uganda_village_id = False

    @api.onchange("uganda_subcounty_id")
    def _onchange_uganda_subcounty_id(self):
        for partner in self:
            if partner.uganda_parish_id.parent_id != partner.uganda_subcounty_id:
                partner.uganda_parish_id = False
                partner.uganda_village_id = False

    @api.onchange("uganda_parish_id")
    def _onchange_uganda_parish_id(self):
        for partner in self:
            if partner.uganda_village_id.parent_id != partner.uganda_parish_id:
                partner.uganda_village_id = False
