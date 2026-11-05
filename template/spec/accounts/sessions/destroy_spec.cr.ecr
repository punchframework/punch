require "../../spec_helper"

private PASSWORD = "correct horse battery"

private def sign_up(client : Punch::Spec::Client, email = "ingrid@example.org") : Punch::Spec::Client
  AccountsSpec.sign_up(client, email, PASSWORD)
end

describe "sessions" do
  it "lists the user's sessions and ends another one" do
    sign_up(Punch::Spec.client)
    laptop = Punch::Spec.client
    laptop.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD})
    phone = Punch::Spec.client
    phone.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD})

    page = laptop.visit(Accounts::Sessions::IndexPage.href)
    page.should have_element("table.sessions tbody tr", count: 3)
    page.should have_element("td strong", text: "(this browser)", count: 1)

    sessions = laptop.get(Accounts::Sessions::Index.path).json["sessions"].as_a
    phone_id = sessions.find! { |entry| !entry["current"].as_bool }["id"].as_i64
    laptop.submit(Accounts::Sessions::Destroy.action(session_id: phone_id)).should redirect_to(Accounts::Sessions::IndexPage.href)
    phone.get(Accounts::Users::Me.path).status.should eq(HTTP::Status::UNAUTHORIZED)
    laptop.get(Accounts::Users::Me.path).status.should eq(HTTP::Status::OK)
  end

  it "does not end another user's session" do
    sign_up(Punch::Spec.client)
    other = Punch::Spec.client
    sign_up(other, "other@example.org")
    other_id = other.get(Accounts::Sessions::Index.path).json["sessions"][0]["id"].as_i64
    client = Punch::Spec.client
    client.submit(Accounts::Sessions::Create.action, form: {"email" => "ingrid@example.org", "password" => PASSWORD})
    response = client.request("DELETE", Accounts::Sessions::Destroy.path(session_id: other_id))
    response.status.should eq(HTTP::Status::NOT_FOUND)
    response.trace.root["punch.authz"].should eq("not_found") # the policy hid it, before the Command ran
    other.get(Accounts::Users::Me.path).status.should eq(HTTP::Status::OK)
  end
end
