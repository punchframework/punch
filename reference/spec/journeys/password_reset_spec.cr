require "../spec_helper"

private PASSWORD = "correct horse battery"

private NEW_PASSWORD = "a new horse, a new battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

private def signed_in(email = "ingrid@example.org", password = PASSWORD) : Punch::Spec::Client
  client = Punch::Spec.client
  client.submit(Accounts::Sessions::Create.action, form: {"email" => email, "password" => password}).should redirect_to(Home::IndexPage.href)
  client
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

private def verified?(email : String) : Bool
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.verified?) } || false
end

describe "password reset" do
  it "answers the same for any address, mails only an account's, and resets once through the link" do
    sign_up(Punch::Spec.client)
    other_browser = signed_in
    Punch::Spec.perform_jobs # the verification mail
    agent = Punch::Spec.bearer(Punch::Spec.api_token(user_id))

    [Punch::Spec.client.submit(Accounts::PasswordResets::Create.action, form: {"email" => "ingrid@example.org"}),
     Punch::Spec.client.submit(Accounts::PasswordResets::Create.action, form: {"email" => "nobody@example.org"})].each do |response|
      response.should redirect_to(Accounts::PasswordResets::CreatePage.href(sent: true))
    end
    mail = mail_to("ingrid@example.org", "Set a new password")
    Punch::Spec.mails(to: "nobody@example.org").should be_empty

    page = Punch::Spec.client.visit(mail.paths.first)
    page.should have_element("input[name=password][type=password]")
    # A refused password shows the form again, still with the token.
    short = Punch::Spec.client.submit(Accounts::Passwords::Reset.action, {token: token(mail)}, form: {"password" => "short"})
    short.should have_field_error("password", "too_short")
    short.should have_element("input[name=token][type=hidden][value='#{token(mail)}']")

    -> {
      Punch::Spec.client.submit(Accounts::Passwords::Reset.action, {token: token(mail)}, form: {"password" => NEW_PASSWORD})
        .should redirect_to(Accounts::Sessions::CreatePage.href)
    }.should publish(Punch::Auth::PasswordChanged, user_id: user_id, reset?: true)
    Punch::Spec.client.submit(Accounts::Passwords::Reset.action, {token: token(mail)}, form: {"password" => NEW_PASSWORD}).status.code.should eq(410)

    # Every session ended; the new password works, the old one does not.
    other_browser.visit(Home::IndexPage.href).should redirect_to(Accounts::Sessions::CreatePage.href)
    # And every API token: whoever knew the old password may have made one.
    Punch::Spec.client.get(Accounts::Tokens::Index.path, headers: agent).status.should eq(HTTP::Status::UNAUTHORIZED)
    signed_in(password: NEW_PASSWORD)
    Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD}).status.code.should eq(422)
    # The link proved the address; the user is told.
    verified?("ingrid@example.org").should be_true
    mail_to("ingrid@example.org", "Your password was reset").text.should contain("set through a reset link")
  end
end
