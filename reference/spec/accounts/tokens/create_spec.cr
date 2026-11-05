require "../../spec_helper"

describe "API tokens" do
  it "are created in the browser, shown once, and work as bearer tokens" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    page = client.visit(Accounts::Tokens::IndexPage.href)
    page.should have_element("p", text: "You have no tokens.")
    page.should have_element(%(select[name="days"] option[selected][value="30"]))

    sent = client.submit(Accounts::Tokens::Create.action, {name: "Claude", days: 90})
    sent.should redirect_to(Accounts::Tokens::IndexPage.href)
    shown = client.visit(sent.headers["Location"])
    token = shown.html.text("section.new-token code") || fail "no new token on the page"
    token.should start_with("inv_")
    shown.should have_element("table.tokens td", text: "Claude")
    client.visit(Accounts::Tokens::IndexPage.href).should_not have_element("section.new-token")

    agent = Punch::Spec.bearer(token)
    me = Punch::Spec.client.get(Accounts::Tokens::Index.path, headers: agent)
    me.status.should eq(HTTP::Status::OK)
    listed = me.json["tokens"].as_a.first
    {listed["name"], listed["current"]}.should eq({"Claude", true})
    expires = Time.parse_rfc3339(listed["expires_at"].as_s)
    (expires - Time.utc).total_days.should be_close(90, 0.01)
  end

  it "tell the user by mail" do
    user = AccountsSpec.user
    Punch::Spec.db.write { |db| Punch::Auth::EmailIdentities.add(db, user.id, Punch::Email.parse("ingrid@example.org").as(Punch::Email), verified_at: Time.utc) }
    Punch::Spec.client.sign_in(user.id).post(Accounts::Tokens::Create.path, json: {name: "CI", days: 7}).status.should eq(HTTP::Status::CREATED)
    Punch::Spec.perform_jobs
    mail = Punch::Spec.mails(to: "ingrid@example.org").find(&.subject.==("An API token was made for your account")) || fail "no notice"
    mail.text.should contain("“CI”")
  end

  it "are created by a JSON client signed in with a session, the token in the answer" do
    user = AccountsSpec.user
    created = Punch::Spec.client.sign_in(user.id).post(Accounts::Tokens::Create.path, json: {name: "CI", days: 7})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["secret"].as_s.should start_with("inv_")
    created.json["token"]["name"].should eq("CI")
  end

  it "need a recent sign-in, so neither an old session nor a token can make one" do
    user = AccountsSpec.user
    stale = Punch::Spec.client.sign_in(user.id, now: Time.utc - 1.hour)
    page = stale.visit(Accounts::Tokens::IndexPage.href)
    page.should_not have_element(%(form[action="#{Accounts::Tokens::Create.path}"]))
    page.should have_element(%(a[href="#{Accounts::Sessions::ReauthenticatePage.href}"]))
    stale.post(Accounts::Tokens::Create.path, json: {name: "CI"}).json["code"].should eq("reauthentication_required")

    agent = Punch::Spec.bearer(Punch::Spec.api_token(user.id))
    refused = Punch::Spec.client.post(Accounts::Tokens::Create.path, json: {name: "Another"}, headers: agent)
    # A token cannot prove a recent sign-in at all (lib/punch/docs/auth.md).
    refused.status.should eq(HTTP::Status::FORBIDDEN)
    refused.json["code"].should eq("forbidden")
  end

  it "refuse an empty name and a lifetime the page does not offer" do
    client = Punch::Spec.client.sign_in(AccountsSpec.user.id)
    blank = client.submit(Accounts::Tokens::Create.action, form: {"name" => " ", "days" => "30"})
    blank.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    blank.should have_field_error("name", "blank")
    client.submit(Accounts::Tokens::Create.action, form: {"name" => "CI", "days" => "1000"}).should have_field_error("days", "invalid_choice")
  end

  it "take no idempotency key, which would store the token" do
    client = Punch::Spec.client.sign_in(AccountsSpec.user.id)
    refused = client.post(Accounts::Tokens::Create.path, json: {name: "CI"}, headers: HTTP::Headers{"Idempotency-Key" => "abc"})
    refused.status.should eq(HTTP::Status::BAD_REQUEST)
    refused.json["code"].should eq("idempotency_key_not_accepted")
  end
end
