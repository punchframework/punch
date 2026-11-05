require "../../spec_helper"

describe "sign-in by email" do
  it "makes no account for an unknown address and says nothing about it" do
    Punch::Spec.client.post(Accounts::MagicLinks::Create.path, json: {email: "nobody@example.org"}).status.code.should eq(200)
    Punch::Spec.perform_jobs
    Punch::Spec.mails.should be_empty
  end
end
