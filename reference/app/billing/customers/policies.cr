module Billing::Customers
  # Whoever holds a role on the customer's organization that permits the
  # operation (`Accounts::Roles`): 403 to a member whose role does not,
  # 404 to everyone else, so customer IDs reveal nothing (lib/punch/docs/authorization.md).
  struct ByRole
    include Punch::Policy

    def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   customer_id : ID) : Punch::Policy::Decision
      organization = Queries.organization(db, customer_id: customer_id) || return not_found
      Punch::Roles.check(db, actor.user.id, operation, on: organization.organization_id)
    end
  end
end
