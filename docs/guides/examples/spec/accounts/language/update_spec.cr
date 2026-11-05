require "../../spec_helper"

private def stored_locale : String?
  Punch::Spec.db.read(&.query_one?("SELECT locale FROM users", &.read(String?)))
end

describe "the interface's language" do
  it "takes only a language the app offers, and follows the browser again without a choice" do
    client = AccountsSpec.client
    client.submit(Accounts::Language::Update.action, form: {"locale" => "en"}).should redirect_to(Accounts::Sessions::IndexPage.href)
    stored_locale.should eq("en")

    refused = client.submit(Accounts::Language::Update.action, form: {"locale" => "fr"})
    refused.should have_field_error("locale", "unsupported_locale")

    client.submit(Accounts::Language::Update.action, form: {"locale" => ""})
    stored_locale.should be_nil
  end
end
