require "../../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

# The one mail of this example to *email* with *subject*, after running
# the jobs.
private def mail_to(email : String, subject : String) : Punch::Mailer::Capture::Captured
  Punch::Spec.perform_jobs
  mails = Punch::Spec.mails(to: email).select(&.subject.==(subject))
  mails.size.should eq(1)
  mails.first
end

private def user_id(email = "ingrid@example.org") : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.user_id) } || fail "no user for #{email}"
end

describe "email addresses" do
  it "refuses to remove the last way to sign in, and tells a removed address" do
    browser = sign_up(Punch::Spec.client)
    Punch::Spec.perform_jobs
    first = Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.list(db, user_id).first.id }
    last = browser.submit(Accounts::Emails::Destroy.action(email_id: first))
    last.status.code.should eq(409)
    last.should have_element(".form-errors li[data-code=last_sign_in_method]")
    browser.delete(Accounts::Emails::Destroy.path(email_id: first)).json["code"].should eq("last_sign_in_method")

    browser.submit(Accounts::Emails::Create.action, form: {"email" => "typo@exmaple.org"})
    typo = Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.list(db, user_id).last.id }
    -> { browser.submit(Accounts::Emails::Destroy.action(email_id: typo)).should redirect_to(Accounts::Sessions::IndexPage.href) }
      .should publish(Accounts::EmailRemoved, user_id: user_id)
    mail_to("typo@exmaple.org", "An email address was removed from your account")
  end
end
