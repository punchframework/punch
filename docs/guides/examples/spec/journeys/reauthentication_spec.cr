require "../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

private def user_id(email = "ingrid@example.org") : Int64
  Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.find(db, Punch::Email.parse(email).as(Punch::Email)).try(&.user_id) } || fail "no user for #{email}"
end

describe "email addresses" do
  it "needs a recent sign-in, and hides the forms without one" do
    sign_up(Punch::Spec.client)
    stale = Punch::Spec.client.sign_in(user_id, now: Time.utc - 1.hour)
    page = stale.visit(Accounts::Sessions::IndexPage.href)
    page.should have_element("p", text: /needs a recent sign-in/)
    page.should have_element("a[href='#{Accounts::Sessions::ReauthenticatePage.href.url}']", text: "Confirm it is you")
    page.should_not have_element("form[action='/accounts/emails']")
    refused = stale.post(Accounts::Emails::Create.path, json: {email: "x@example.org"})
    refused.status.code.should eq(403)
    refused.json["code"].should eq("reauthentication_required")

    # The password makes it recent again.
    confirm = stale.visit(Accounts::Sessions::ReauthenticatePage.href)
    confirm.should have_element("input[name='current_password'][type='password']")
    stale.submit(Accounts::Sessions::Reauthenticate.action, form: {"current_password" => "wrong password!"}).status.code.should eq(422)
    stale.submit(Accounts::Sessions::Reauthenticate.action, form: {"current_password" => PASSWORD}).should redirect_to(Accounts::Sessions::IndexPage.href)
    stale.visit(Accounts::Sessions::IndexPage.href).should have_element("form[action='/accounts/emails']")
    # Another user's address is not found.
    other = Punch::Spec.client.sign_in(AccountsSpec.user.id)
    first = Punch::Spec.db.read { |db| Punch::Auth::EmailIdentities.list(db, user_id).first.id }
    other.delete(Accounts::Emails::Destroy.path(email_id: first)).status.code.should eq(404)
  end
end
