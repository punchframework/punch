# The app behind spec/cli/openapi_cli_spec.cr: a few operations whose
# document punch openapi derives, with doc comments as descriptions. Its
# entry point is src/main.cr, so specs can require this file.
require "punch"

module Shop::Invoices
  struct ID < Punch::TypedID
  end

  # Where an invoice is in its life.
  enum State
    Draft
    Sent
  end

  # An invoice as the API shows it.
  @[Punch::Status(200)]
  struct Invoice
    include JSON::Serializable

    getter id : ID
    # The number printed on the invoice.
    getter number : String
    getter state : State
    getter recipient : Punch::Email?

    def initialize(@id, @number, @state, @recipient)
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(409)]
  struct AlreadySent
    include JSON::Serializable

    getter sent_at : Time

    def initialize(@sent_at)
    end
  end

  # Another invoice has this number.
  @[Punch::Status(422)]
  struct DuplicateNumber
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(201)]
  struct Created
    include JSON::Serializable

    getter id : ID

    def initialize(@id)
    end
  end

  # Lists invoices, newest first.
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      getter state : State?
      getter limit : Int32 = 20
    end

    def call(input : Input, db : Punch::Reader)
      [] of Invoice
    end
  end

  @[Punch::Public]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    def call(input : Input, db : Punch::Reader) : Invoice | NotFound
      NotFound.new
    end
  end

  # The invoice as a page for people, on the same path as `Show`.
  @[Punch::Status(200)]
  struct InvoiceView
    include Punch::Component

    def initialize(@id : ID)
    end

    def view(v : Punch::View) : Nil
      v.document("Invoice #{@id}") do
        v.h1 "Invoice #{@id}"
        v.form(Send.action(invoice_id: @id)) { |form| form.submit "Send" }
      end
    end
  end

  @[Punch::Forms(Send)]
  @[Punch::Public]
  struct ShowPage < Punch::Page
    alias Input = Show::Input

    def call(input : Input, db : Punch::Reader) : InvoiceView | NotFound
      input.invoice_id.value == 1 ? InvoiceView.new(input.invoice_id) : NotFound.new
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter number : Punch::Slug
      getter recipient : Punch::Email?
    end

    def call(input : Input, db : Punch::Writer) : Created | DuplicateNumber
      Created.new(ID.parse(1).as(ID))
    end
  end
end

# Operations in app/ are documented too.
require "../app/shop/invoices/operations/send"
