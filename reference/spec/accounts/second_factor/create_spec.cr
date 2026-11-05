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
  it "is set up from the account page, confirmed with the app's first code, and announced by mail" do
    client, _, _ = with_app
    page = client.visit(Accounts::Sessions::IndexPage.href)
    page.should have_element("p", text: "On, with an authenticator app. 10 recovery codes left.")
    page.should have_element("form[action='/accounts/second_factor/regenerate']")
    session_method.should eq("totp")

    Punch::Spec.perform_jobs
    Punch::Spec.mails(to: EMAIL).map(&.subject).should contain("Two-step sign-in is on")
  end

  it "shows and confirms a pending setup only to a recent sign-in" do
    user = AccountsSpec.user
    setup = Punch::Spec.db.write { |db| Punch::Auth::SecondFactors.start(db, user.id) }.as(Punch::Auth::TOTPSetup)
    stale = Punch::Spec.client.sign_in(user.id, now: Time.utc - 1.hour)
    stale.visit(Accounts::SecondFactor::SetupPage.href).body.should_not contain(setup.secret_text.unwrap)
    refused = stale.post(Accounts::SecondFactor::Confirm.path, json: {code: Punch::Spec.totp_code(setup.secret.unwrap)})
    refused.json["code"].should eq("reauthentication_required")
    Punch::Spec.db.read { |db| Punch::Auth::SecondFactors.enabled?(db, user.id) }.should be_false
  end
end
