require "../../spec_helper"

private PASSWORD = "correct horse battery"

# Signs up and follows the mailed link; signing in is the example's.
private def sign_up(email = "ingrid@example.org", password = PASSWORD) : Nil
  Punch::Spec.client.submit(Accounts::SignUp::Create.action, form: {"name" => "Ingrid", "email" => email, "password" => password})
    .should redirect_to(Accounts::SignUp::CreatePage.href(sent: true))
  AccountsSpec.verify(email)
end

describe "signing up and in with a browser" do
  it "signs in, and answers a wrong password like an unknown address" do
    sign_up
    client = Punch::Spec.client
    client.visit(Accounts::Sessions::CreatePage.href).should have_element("input[name=password][autocomplete=current-password]")
    client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD})
      .should redirect_to(Home::IndexPage.href)
    client.visit(Home::IndexPage.href).status.should eq(HTTP::Status::OK)

    wrong = Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => "not my password"})
    unknown = Punch::Spec.client.submit(Accounts::Sessions::Create.action, form: {"email" => "nobody@example.org", "password" => PASSWORD})
    [wrong, unknown].each do |response|
      response.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      response.should have_element(".form-errors li[data-code=invalid_credentials]", text: "The email address or password is wrong.")
      response.headers["Set-Cookie"]?.should be_nil
    end
  end

  it "signs in over JSON for API clients" do
    sign_up
    client = Punch::Spec.client
    response = client.post(Accounts::Sessions::Create.path, json: {email: "ingrid@example.org", password: PASSWORD})
    response.status.should eq(HTTP::Status::OK)
    client.get(Accounts::Users::Me.path).json["name"].should eq("Ingrid")
    client.post(Accounts::Sessions::Create.path, json: {email: "ingrid@example.org", password: "nope"}).json["code"].should eq("invalid_credentials")
  end

  it "throttles guessing at one address, whatever the client" do
    sign_up
    10.times do
      Punch::Spec.client.post(Accounts::Sessions::Create.path, json: {email: "ingrid@example.org", password: "guess"}).status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    end
    limited = Punch::Spec.client.post(Accounts::Sessions::Create.path, json: {email: "ingrid@example.org", password: PASSWORD})
    limited.should be_rate_limited("accounts.sessions.create.email")
  end
end
