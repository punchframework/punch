module Billing::Invoices
  # Mails a sent invoice to its customer. Deferred (lib/punch/docs/events.md): a job
  # through the outbox, so the mail goes out exactly when the invoice was
  # sent, after the response, and is retried if delivery fails.
  #
  # The mail is in the customer's language, else in the organization's,
  # else in the app's default.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct MailInvoice
    include Punch::Subscriber(InvoiceSent)

    def call(event : InvoiceSent, job : Punch::Job::Context) : Punch::Job::Result
      invoice, customer = job.read { |db| {Store.load(db, event.invoice_id), Customers::Table.find(db, event.customer_id)} }
      return discard("invoice #{event.invoice_id} is gone") unless invoice.is_a?(Invoice::Issued) && customer

      expires_at = Time.utc.at_beginning_of_second + Sharing::VALID
      link = SharedPage.href(token: Sharing.token(invoice, expires_at))
      locale = Punch::I18n.locale((customer.locale || Accounts::Mailing.organization_locale(job, customer.organization_id)).try(&.to_s))
      mail = InvoiceMail.new(invoice, customer, link, Invoicing::Credentials.current.issuer.name.value)
      Punch::Mailer.deliver(mail, locale: locale, job: job)
    end
  end
end
