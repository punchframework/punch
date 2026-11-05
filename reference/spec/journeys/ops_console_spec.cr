require "../spec_helper"

describe "the ops console" do
  it "is open to operators and does not exist for other users" do
    operator = AccountsSpec.operator
    other = AccountsSpec.client
    operator.visit(Punch::Ops::Console::IndexPage.href).status.should eq(HTTP::Status::OK)
    operator.visit(Billing::Invoices::IndexPage.href).should have_element("nav a", text: "Ops")
    other.visit(Punch::Ops::Console::IndexPage.href).status.should eq(HTTP::Status::NOT_FOUND)
    other.visit(Billing::Invoices::IndexPage.href).should have_element("nav a", count: 3) # invoices, customers, billing profile; no ops
  end

  it "shows a job's runs, and the reminder job among the recurring ones" do
    Punch::Spec.ops
    Punch::Job::Queue.enqueue(Billing::Invoices::Remind.new(Billing::Invoices::ID.parse(999_i64).as(Billing::Invoices::ID)))
    job = Punch::Spec.perform_jobs.first
    operator = AccountsSpec.operator
    page = operator.visit(Punch::Ops::Console::JobPage.href(job_id: job.id))
    page.should have_element("h1", text: "Job #{job.id}: Billing::Invoices::Remind")
    page.should have_element("table.runs td", text: "discarded")
    page.should have_element("pre", text: "invoice #{Billing::Invoices::ID.parse(999_i64)} was deleted")
    operator.visit(Punch::Ops::Console::JobsPage.href).should have_element("table.recurring td", text: "Punch::Job::Queue::Purge")
  end

  it "shows a failed payment webhook with its stored request, and retries it" do
    body = {event: "payment.succeeded", data: {payment_id: "pay_console", invoice_number: "INV-424242", amount: 100, currency: "EUR", paid_at: "2026-10-12T09:30:00Z"}}.to_json
    Punch::Spec.client.deliver_webhook(Billing::Payments::Provider::Receive.path, body, secret: BillingSpec::WEBHOOK_SECRET)
      .status.should eq(HTTP::Status::NO_CONTENT)
    Punch::Spec.perform_jobs
    invocation = Punch::Spec.webhooks("payments").last
    operator = AccountsSpec.operator
    operator.visit(Punch::Ops::Console::WebhooksPage.href).should have_element("table.invocations td", text: "no sent invoice INV-424242")
    page = operator.visit(Punch::Ops::Console::WebhookPage.href(invocation_id: invocation.id))
    page.should have_element("pre", text: /INV-424242/)
    page.should have_element("dl.headers dt", text: "webhook-id")
    operator.submit(Punch::Ops::Console::RetryWebhook.action(invocation_id: invocation.id))
      .should redirect_to(Punch::Ops::Console::WebhookPage.href(invocation_id: invocation.id))
    -> { Punch::Spec.perform_jobs }.should publish(Punch::Webhook::ProcessingFailed, provider: "payments", state: "failed", times: 1)
    Punch::Spec.webhooks("payments").last.attempts.should eq(2)
  end

  it "shows where requests and named queries spend their time" do
    Punch::Spec.ops
    operator = AccountsSpec.operator
    operator.get(Billing::Invoices::Index.path).status.should eq(HTTP::Status::OK)
    operator.visit(Punch::Ops::Console::PerformancePage.href).should have_element("table.stats a", text: "GET /billing/invoices")
    queries = operator.visit(Punch::Ops::Console::PerformancePage.href(kind: Punch::Ops::StatsKind::Query))
    queries.should have_element("table.stats a", text: /Billing::Invoices::Queries/)
  end
end
