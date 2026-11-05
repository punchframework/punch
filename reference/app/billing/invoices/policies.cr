module Billing::Invoices
  # Whoever holds a role on the invoice's organization that permits the
  # operation (`Accounts::Roles`): a member sees an invoice but may not
  # send it (403), and to anyone without a role there it does not exist
  # (404).
  struct ByRole
    include Punch::Policy

    def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   invoice_id : ID) : Punch::Policy::Decision
      organization = Queries.organization(db, invoice_id: invoice_id) || return not_found
      Punch::Roles.check(db, actor.user.id, operation, on: organization.organization_id)
    end
  end
end
