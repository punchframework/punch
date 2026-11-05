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

# The token of the one link in *mail*.
private def token(mail : Punch::Mailer::Capture::Captured) : String
  path = mail.paths.first? || fail "no link in #{mail.text}"
  URI.parse(path).query_params["token"]
end

private def user_id(email = "ingrid@example.org") : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.user_id) } || fail "no user for #{email}"
end

describe "email addresses" do
  it "adds one, which gets a verification link while the verified ones are told" do
    browser = sign_up(Punch::Spec.client)
    verify = mail_to("ingrid@example.org", "Verify your email address")
    Punch::Spec.client.submit(Accounts::Emails::Verify.action, {token: token(verify)})

    -> { browser.submit(Accounts::Emails::Create.action, form: {"email" => "ingrid@work.example.org"}).should redirect_to(Accounts::Sessions::IndexPage.href) }
      .should publish(Accounts::EmailAdded, user_id: user_id)
    mail_to("ingrid@work.example.org", "Verify your email address")
    mail_to("ingrid@example.org", "An email address was added to your account").text.should contain("ingrid@work.example.org was added")
    page = browser.visit(Accounts::Sessions::IndexPage.href)
    page.should have_element("ul.addresses li", count: 2)
    page.should have_element("ul.addresses li small", text: "(verified)", count: 1)
    browser.submit(Accounts::Emails::Create.action, form: {"email" => "Ingrid@Example.org"}).should have_field_error("email", "taken")
  end
end
