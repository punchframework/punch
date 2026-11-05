require "../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

private def signed_in(email = "ingrid@example.org", password = PASSWORD) : Punch::Spec::Client
  client = Punch::Spec.client
  client.submit(Accounts::Sessions::Create.action, form: {"email" => email, "password" => password}).should redirect_to(Home::IndexPage.href)
  client
end

private def user_id(email = "ingrid@example.org") : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.user_id) } || fail "no user for #{email}"
end

describe "auth events" do
  it "records sign-ins, refused ones, and ended sessions" do
    sign_up(Punch::Spec.client)
    failed = Punch::Spec.published(Punch::Auth::SignInFailed) do
      Punch::Spec.client.post(Accounts::Sessions::Create.path, json: {email: "ingrid@example.org", password: "guess"})
    end
    failed.map(&.user_id).should eq([user_id])
    browser = signed_in
    -> { browser.submit(Accounts::Sessions::SignOut.action) }.should publish(Punch::Auth::SessionRevoked, reason: "sign_out")
  end
end
