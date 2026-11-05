require "../../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org", password = PASSWORD) : Punch::Spec::Response
  client.submit(Accounts::SignUp::Create.action, form: {"name" => "Ingrid", "email" => email, "password" => password})
end

private def stored_locale : String?
  Punch::Spec.db.read(&.query_one?("SELECT locale FROM users", &.read(String?)))
end

describe "signing up and in with a browser" do
  it "signs up, is told to follow the mailed link, and signs in after it" do
    client = Punch::Spec.client
    page = client.visit(Accounts::SignUp::CreatePage.href)
    page.should have_element("input[name=password][type=password][autocomplete=new-password]")
    sign_up(client).should redirect_to(Accounts::SignUp::CreatePage.href(sent: true))
    client.visit(Accounts::SignUp::CreatePage.href(sent: true)).should have_element("p", text: /follow it, then sign in/i)
    client.visit(Home::IndexPage.href).should_not have_element("form[action='/accounts/sessions/sign_out']")
    AccountsSpec.verify("ingrid@example.org")
    client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD}).should redirect_to(Home::IndexPage.href)
    home = client.visit(Home::IndexPage.href)
    home.should have_element("header strong", text: "Ingrid")
    home.should have_element("form[action='/accounts/sessions/sign_out'] button", text: "Sign out")
  end

  it "says when an address is taken, rolls the new user back, and never echoes the password" do
    sign_up(Punch::Spec.client)
    again = sign_up(Punch::Spec.client, "Ingrid@Example.org")
    again.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    again.should have_field_error("email", "taken")
    again.body.should_not contain(PASSWORD)
    Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM users", &.read(Int64))).should eq(1)

    short = sign_up(Punch::Spec.client, "other@example.org", "too short")
    short.should have_field_error("password", "too_short")
  end
end

describe "the interface's language" do
  it "stores the language a user signs up with, and keeps it over the browser's" do
    client = Punch::Spec.client
    client.language = "de"
    client.submit(Accounts::SignUp::Create.action, form: {"name" => "Ingrid", "email" => "ingrid@example.org", "password" => "correct horse battery"})
    stored_locale.should eq("de")
    AccountsSpec.verify("ingrid@example.org")
    client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => "correct horse battery"})
    client.language = "en"
    page = client.visit(Home::IndexPage.href)
    page.should have_element("main > h1", text: "Willkommen")
    page.headers["Vary"]?.to_s.should_not contain("Accept-Language")
  end
end
