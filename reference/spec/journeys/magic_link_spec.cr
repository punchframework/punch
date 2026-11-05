require "../spec_helper"

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

# The token of the one link in *mail*.
private def token(mail : Punch::Mailer::Capture::Captured) : String
  path = mail.paths.first? || fail "no link in #{mail.text}"
  URI.parse(path).query_params["token"]
end

private def verified?(email : String) : Bool
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.verified?) } || false
end

describe "sign-in by email" do
  it "mails a link that signs in once and verifies the address" do
    sign_up(Punch::Spec.client)
    Punch::Spec.perform_jobs
    Punch::Spec.client.submit(Accounts::MagicLinks::Create.action, form: {"email" => "ingrid@example.org"})
      .should redirect_to(Accounts::MagicLinks::CreatePage.href(sent: true))
    mail = mail_to("ingrid@example.org", "Your sign-in link")
    browser = Punch::Spec.client
    browser.visit(mail.paths.first).should have_element("form button", text: "Sign in")
    -> { browser.submit(Accounts::MagicLinks::SignIn.action, {token: token(mail)}).should redirect_to(Home::IndexPage.href) }
      .should publish(Punch::Auth::SignInSucceeded, method: "magic_link")
    browser.visit(Home::IndexPage.href).status.code.should eq(200)
    verified?("ingrid@example.org").should be_true
    Punch::Spec.client.submit(Accounts::MagicLinks::SignIn.action, {token: token(mail)}).status.code.should eq(410)
  end
end
