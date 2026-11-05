require "../../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

describe "sessions" do
  it "signs out" do
    client = Punch::Spec.client
    sign_up(client)
    client.submit(Accounts::Sessions::SignOut.action).should redirect_to(Accounts::Sessions::CreatePage.href)
    client.get(Accounts::Users::Me.path).status.should eq(HTTP::Status::UNAUTHORIZED)
  end
end
