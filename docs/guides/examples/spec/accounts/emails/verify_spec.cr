require "../../spec_helper"

private PASSWORD = "correct horse battery"

# The one mail of this example to *email* with *subject*, after running
# the jobs.
private def mail_to(email : String, subject : String) : Punch::Mailer::Capture::Captured
  Punch::Spec.perform_jobs
  mails = Punch::Spec.mails(to: email).select(&.subject.==(subject))
  mails.size.should eq(1)
  mails.first
end

# The token of the one link in *mail*.
private def token(mail : Punch::Mailer::Capture::Captured) : String
  path = mail.paths.first? || fail "no link in #{mail.text}"
  URI.parse(path).query_params["token"]
end

private def verified?(email : String) : Bool
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.verified?) } || false
end

describe "email verification" do
  it "mails a link at sign-up; the page only shows a button, which verifies the address once" do
    Punch::Spec.client.submit(Accounts::SignUp::Create.action, form: {"name" => "Ingrid", "email" => "ingrid@example.org", "password" => PASSWORD})
      .should redirect_to(Accounts::SignUp::CreatePage.href(sent: true))
    mail = mail_to("ingrid@example.org", "Verify your email address")
    mail.text.should contain("please confirm that ingrid@example.org is yours")
    link = mail.paths.first

    # A mail scanner fetches the link: nothing happens.
    scanner = Punch::Spec.client.visit(link)
    scanner.should have_element("form button", text: "Verify address")
    verified?("ingrid@example.org").should be_false

    browser = Punch::Spec.client
    browser.submit(Accounts::Emails::Verify.action, {token: token(mail)}).should redirect_to(Accounts::Sessions::CreatePage.href)
    verified?("ingrid@example.org").should be_true
    again = browser.submit(Accounts::Emails::Verify.action, {token: token(mail)})
    again.status.code.should eq(410)
    Punch::Spec.client.visit(link).should have_element("p", text: "This link has expired or was already used.")
  end

  it "lets the password sign in only once an address of the account is verified" do
    sign_up = Punch::Spec.client.submit(Accounts::SignUp::Create.action, form: {"name" => "Ingrid", "email" => "ingrid@example.org", "password" => PASSWORD})
    sign_up.should redirect_to(Accounts::SignUp::CreatePage.href(sent: true))
    sign_up.headers["Set-Cookie"]?.to_s.should_not contain("__Host-session=")
    form = {"email" => "ingrid@example.org", "password" => PASSWORD}
    refused = Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: form)
    refused.status.code.should eq(403)
    refused.should have_element(".form-errors li[data-code=not_verified]")
    # A wrong password answers as for any address.
    Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => "not it"}).status.code.should eq(422)

    mail = mail_to("ingrid@example.org", "Verify your email address")
    Punch::Spec.client.submit(Accounts::Emails::Verify.action, {token: token(mail)})
    Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: form).should redirect_to(Home::IndexPage.href)
  end
end
