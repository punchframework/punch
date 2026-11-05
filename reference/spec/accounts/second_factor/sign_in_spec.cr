require "../../spec_helper"

private PASSWORD = "correct horse battery"

private EMAIL = "ingrid@example.org"

private def sign_up(client = Punch::Spec.client) : Punch::Spec::Client
  AccountsSpec.sign_up(client, EMAIL, PASSWORD)
end

private def user_id : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(EMAIL).as(Punch::Email)).try(&.user_id) } || fail "no user"
end

private def session_method : String
  Punch::Spec.db.read(&.query_one?("SELECT method FROM punch_sessions ORDER BY id DESC LIMIT 1", &.read(String))) || fail "no session"
end

# Signs up and turns the app on through the account page; returns the
# client, the secret, and the recovery codes shown during the setup.
private def with_app : {Punch::Spec::Client, Bytes, Array(String)}
  client = sign_up
  client.visit(Accounts::Sessions::IndexPage.href).should have_element("form[action='/accounts/second_factor'] button", text: "Set up an authenticator app")
  client.submit(Accounts::SecondFactor::Create.action).should redirect_to(Accounts::SecondFactor::SetupPage.href)
  setup = Punch::Spec.db.read { |db| Punch::Auth::SecondFactors.setup(db, user_id) } || fail "no setup"
  page = client.visit(Accounts::SecondFactor::SetupPage.href)
  page.should have_element("code", text: setup.secret_text.unwrap)
  page.should have_element("ul.recovery-codes li", count: 10)
  page.should have_element("a[href^='otpauth://totp/Invoicing:ingrid%40example.org?secret=']")
  page.should have_element("input[name='code'][autocomplete='one-time-code']")

  client.submit(Accounts::SecondFactor::Confirm.action, form: {"code" => "000000"}).status.code.should eq(422)
  client.submit(Accounts::SecondFactor::Confirm.action, form: {"code" => Punch::Spec.totp_code(setup.secret.unwrap)})
    .should redirect_to(Accounts::Sessions::IndexPage.href)
  # The confirming code is used up; the specs sign in with the next one.
  Punch::Spec.db.write(&.exec("UPDATE punch_totp_authenticators SET last_step = 0"))
  {client, setup.secret.unwrap, setup.recovery_codes.unwrap}
end

describe "two-step sign-in" do
  it "asks for the code after the password, and signs in with it" do
    _, secret, _ = with_app
    browser = Punch::Spec.client
    browser.submit(Accounts::Sessions::Create.action, form: {"email" => EMAIL, "password" => PASSWORD})
      .should redirect_to(Accounts::SecondFactor::SignInPage.href)
    browser.visit(Accounts::Sessions::IndexPage.href).should redirect_to(Accounts::Sessions::CreatePage.href)

    step = browser.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => "000000"})
    step.status.code.should eq(422)
    step.should have_element("input[name='code']")
    step.body.should_not contain("000000") # a code is not written back
    browser.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => Punch::Spec.totp_code(secret)})
      .should redirect_to(Home::IndexPage.href)
    session_method.should eq("password+totp")
    browser.visit(Accounts::Sessions::IndexPage.href).status.code.should eq(200)
  end

  it "takes a recovery code in place of the app, once" do
    _, _, codes = with_app
    browser = Punch::Spec.client
    browser.submit(Accounts::Sessions::Create.action, form: {"email" => EMAIL, "password" => PASSWORD})
    browser.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => Punch::Auth::SecondFactors.format(codes.first).upcase})
      .should redirect_to(Home::IndexPage.href)
    session_method.should eq("password+recovery_code")

    again = Punch::Spec.client
    again.submit(Accounts::Sessions::Create.action, form: {"email" => EMAIL, "password" => PASSWORD})
    again.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => codes.first}).status.code.should eq(422)
    again.visit(Accounts::Sessions::IndexPage.href).should redirect_to(Accounts::Sessions::CreatePage.href)
  end

  it "makes a mailed sign-in link the first step only" do
    _, secret, _ = with_app
    browser = Punch::Spec.client
    id = user_id
    token = Punch::Spec.db.write { |db| Punch::Auth::OneTimeTokens.issue(db, Accounts::Links::MAGIC_LINK, 15.minutes, user_id: id, subject: EMAIL) }
    browser.submit(Accounts::MagicLinks::SignIn.action, {token: token.unwrap}).should redirect_to(Accounts::SecondFactor::SignInPage.href)
    browser.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => Punch::Spec.totp_code(secret)}).should redirect_to(Home::IndexPage.href)
    session_method.should eq("magic_link+totp")
  end
end
