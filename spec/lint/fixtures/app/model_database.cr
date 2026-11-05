# Punch/ModelDatabase: database handles in app code, outside operations and
# stores. The path contains app/, so the rule applies.
module Billing::Invoice
  record Draft, id : Int64 do
    def total(db : Punch::Reader) : Int64 # expect
      0_i64
    end

    def save(db : Punch::Writer) : Nil # expect
    end

    def open : Punch::Database # expect
    end
  end

  def self.helper(db : Punch::Databases) # expect
    Punch::Database::RowError            # not a handle
  end
end

module Billing::Invoices
  # Operations take handles.
  class Show < Punch::Query
    def call(input : Input, db : Punch::Reader) : Nil
    end
  end

  class Send < Command
    def call(input : Input, db : Punch::Writer) : Nil
    end
  end

  struct ShowPage < Punch::Page
    def call(input : Input, db : Punch::Reader) : Nil
    end
  end

  # Stores load and save.
  module Store
    def self.load(db : Punch::Reader | Punch::Writer, id : Int64) : Nil
    end
  end

  class InvoiceStore
    def save(db : Punch::Writer) : Nil
    end
  end

  struct Summary
    def initialize(db : Punch::Reader) # expect
    end
  end

  # The app's actor loads itself in the operation's transaction.
  struct Actor
    include Punch::Auth::Actor

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    end
  end

  # Including another module named Actor is not enough.
  struct Visitor
    include Actor

    def self.load(db : Punch::Reader) : Nil # expect
    end
  end

  # A webhook provider's `process` writes like a Command.
  @[Punch::Webhook::Provider("payments")]
  struct Provider < Punch::Webhook::Inbound
    def process(event : Paid, db : Punch::Writer) : Punch::Webhook::Outcome
    end
  end

  struct Handler < Inbound
    def process(event : Paid, db : Punch::Writer) : Nil # expect
    end
  end

  # A policy decides inside the operation's transaction.
  struct Owner
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, *, note_id : Int64) : Punch::Policy::Decision
    end
  end

  struct Rules
    include Policy

    def self.check(db : Punch::Reader) : Nil # expect
    end
  end

  # An inline subscriber writes in the Command's transaction.
  @[Punch::Subscriber::Delivery(:inline)]
  struct CountSent
    include Punch::Subscriber(InvoiceSent)

    def call(event : InvoiceSent, db : Punch::Writer) : Nil
    end
  end

  # Including another generic named Subscriber is not enough.
  struct Listener
    include Subscriber(InvoiceSent)

    def call(event : InvoiceSent, db : Punch::Writer) : Nil # expect
    end
  end
end
