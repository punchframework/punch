module Billing::Invoices
  struct ListView
    include Punch::Component

    def initialize(@page : Page, @actor : Invoicing::Actor, @next_page : Punch::Href?, @input : Index::Input)
    end

    def view(v : Punch::View) : Nil
      t = v.t.invoices
      v.render Invoicing::Layout.new(t.title, @actor, morph: true) do
        v.h1 t.title
        customer_id = @input.filter.customer_id
        v.p { v.a t.new_invoice, href: CreatePage.href(customer_id: customer_id) }
        if customer_id
          # The frame a customer's page loads lazily (`Customers::EditView`).
          v.frame(customer_id, "invoices", target: "_top") { list(v) }
        else
          list(v)
        end
      end
    end

    private def list(v : Punch::View) : Nil
      t = v.t.invoices
      filter_form(v)
      if @page.invoices.empty?
        v.p t.none
      else
        v.table(class: "invoices") do
          v.thead do
            v.tr { [t.invoice, t.customer, t.status, t.total, t.due].each { |label| v.th label, scope: "col" } }
          end
          v.tbody { @page.invoices.each { |invoice| v.render ListRow.new(invoice) } }
        end
      end
      if next_page = @next_page
        v.p { v.a t.next_page, href: next_page, rel: "next" }
      end
    end

    # Searches by number or customer, and narrows by state; on a
    # customer's list the customer stays. A new filter starts at the first
    # page.
    private def filter_form(v : Punch::View) : Nil
      t = v.t.invoices
      v.filter_form(IndexPage, @input, class: "filter") do |form|
        form.fields(:filter, Queries::Page::Filter) do |filter|
          filter.field :q, hint: t.search_hint
          filter.field :status, options: Invoice::Status.values.map { |status| {status, Invoices.state(v.locale, status, false)} }
          filter.field :customer_id, as: :hidden
        end
        form.field :limit, as: :hidden
        form.submit t.filter
      end
    end
  end

  # One invoice in the list, with its DOM ID, so a change replaces or
  # removes it (`IndexPage#live`).
  struct ListRow
    include Punch::Component

    def initialize(@invoice : Summary)
    end

    def view(v : Punch::View) : Nil
      invoice, locale = @invoice, v.locale
      v.tr(id: Punch.dom_id(invoice.id), class: ["invoice", ("overdue" if invoice.overdue?)]) do
        v.td { v.a Invoices.title(locale, invoice.number, invoice.id), href: ShowPage.href(invoice_id: invoice.id) }
        v.td invoice.customer_name.to_s
        v.td Invoices.state(locale, invoice.status, invoice.overdue?)
        v.td locale.money(invoice.total, invoice.currency)
        v.td { invoice.due_at.try { |due| v.time locale.date(due), datetime: due } }
      end
    end
  end

  # The search screen: the invoices of the organization the actor works
  # in, a page at a time, found by number or customer and narrowed by
  # state. `GET /billing/invoices` in a browser.
  #
  # Open in a browser, it follows the organization's invoices (`live`,
  # lib/punch/docs/views.md): a changed row is replaced where it is shown, a row that no
  # longer matches the filter is removed, and where an invoice may have
  # come into the list (a new draft, or one that now matches the state or
  # the search), Turbo refreshes the page by morphing it.
  @[Punch::AgentReadable(entry: true)]
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      page = Index.new.call(input, db, actor)
      next_page = page.next_after.try do |after|
        # The cursor holds the position only: the next page repeats the filter.
        IndexPage.href(filter: input.filter, after: after, limit: input.limit)
      end
      ListView.new(page, actor, next_page, input)
    end

    # New drafts go to the end of the list, on whichever page that is.
    def live(event : InvoiceDrafted, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      return unless event.organization_id == actor.organization_id

      Punch::TurboStream.build(&.refresh) if Index.listed(db, event.invoice_id, input, actor)
    end

    # Revising a draft changes neither its state nor what the search finds.
    def live(event : DraftRevised, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      changed(event.invoice_id, input, db, actor, entering: false)
    end

    # Sending changes the state and gives the number the search finds.
    def live(event : InvoiceSent, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      filter = input.filter
      changed(event.invoice_id, input, db, actor, entering: !filter.status.nil? || !filter.q.nil?)
    end

    # A payment changes the state only.
    def live(event : InvoicePaid, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      changed(event.invoice_id, input, db, actor, entering: !input.filter.status.nil?)
    end

    def live(event : DraftDeleted, input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Punch::TurboStream?
      Punch::TurboStream.build(&.remove(event.invoice_id)) if event.organization_id == actor.organization_id
    end

    # What a change to invoice *id* means for the viewer's list: the row
    # again if it still matches, a refresh when it may not have been
    # listed before the change (*entering*), and its removal when it no
    # longer matches. Nothing for another organization's invoice.
    private def changed(id : ID, input : Input, db : Punch::Reader, actor : Invoicing::Actor, *, entering : Bool) : Punch::TurboStream?
      if summary = Index.listed(db, id, input, actor)
        Punch::TurboStream.build { |stream| entering ? stream.refresh : stream.replace(id, ListRow.new(summary), morph: true) }
      elsif Queries.organization(db, invoice_id: id).try(&.organization_id) == actor.organization_id
        Punch::TurboStream.build(&.remove(id))
      end
    end
  end
end
