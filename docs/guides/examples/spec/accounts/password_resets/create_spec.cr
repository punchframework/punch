require "../../spec_helper"

describe "password reset" do
  it "throttles requests for one address" do
    5.times { Punch::Spec.client.post(Accounts::PasswordResets::Create.path, json: {email: "ingrid@example.org"}).status.code.should eq(200) }
    Punch::Spec.client.post(Accounts::PasswordResets::Create.path, json: {email: "Ingrid@example.org"}).should be_rate_limited("accounts.password_resets.create.email")
  end
end
