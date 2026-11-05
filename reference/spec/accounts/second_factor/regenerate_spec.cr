require "../../spec_helper"

private PASSWORD = "correct horse battery"

private EMAIL = "ingrid@example.org"

private def sign_up(client = Punch::Spec.client) : Punch::Spec::Client
  AccountsSpec.sign_up(client, EMAIL, PASSWORD)
end

private def user_id : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(EMAIL).as(Punch::Email)).try(&.user_id) } || fail "no user"
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
  it "replaces the recovery codes, shows the new ones until saved" do
    client, _, codes = with_app
    client.submit(Accounts::SecondFactor::Regenerate.action).should redirect_to(Accounts::Sessions::IndexPage.href)
    page = client.visit(Accounts::Sessions::IndexPage.href)
    page.should have_element("ul.recovery-codes li", count: 10)
    page.should_not have_element("ul.recovery-codes li code", text: Punch::Auth::SecondFactors.format(codes.first))
    client.submit(Accounts::SecondFactor::Seen.action).should redirect_to(Accounts::Sessions::IndexPage.href)
    client.visit(Accounts::Sessions::IndexPage.href).should_not have_element("ul.recovery-codes")

    browser = Punch::Spec.client
    browser.submit(Accounts::Sessions::Create.action, form: {"email" => EMAIL, "password" => PASSWORD})
    browser.submit(Accounts::SecondFactor::SignIn.action, form: {"code" => codes.first}).status.code.should eq(422)
  end
end
