require "../../src/punch"

struct Member
  include Punch::Auth::Actor

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new
  end
end

struct InvoiceID < Punch::TypedID
end

struct ByOwner
  include Punch::Policy

  def self.check(actor : Member, db : Punch::Reader | Punch::Writer, *, id : InvoiceID) : Punch::Policy::Decision
    Punch::Policy::Decision::Allow
  end
end

module Billing::Invoices
  @[Punch::Authorize(ByOwner)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter invoice_id : InvoiceID
    end

    def call(input : Input, db : Punch::Reader, actor : Member) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
