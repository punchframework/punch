require "../../spec_helper"

private def expect_not_found(response : Punch::Spec::Response) : Nil
  {response.status, response.json["code"]}.should eq({HTTP::Status::NOT_FOUND, "not_found"})
end

# Two users, each administrator of an organization of their own, and
# clients signed in as them.
private def two_users
  ada, bob = AccountsSpec.user("Ada Admin"), AccountsSpec.user("Bob Member")
  organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, ada.id) }
  {ada, bob, organization, Punch::Spec.client.sign_in(ada.id), Punch::Spec.client.sign_in(bob.id)}
end

describe "organizations" do
  it "keeps the choice per session, and forgets it with the role" do
    ada, bob, organization, _, bob_client = two_users
    AccountsSpec.give(bob.id, :member, on: organization)
    other_session = Punch::Spec.client.sign_in(bob.id)
    bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization))
    bob_client.get(Accounts::Organizations::Index.path).json["organizations"][0]["current"].as_bool.should be_true
    other_session.get(Accounts::Organizations::Index.path).json["organizations"][0]["current"].as_bool.should be_false

    ada_client = Punch::Spec.client.sign_in(ada.id)
    ada_client.delete(Accounts::Organizations::Members::Destroy.path(organization_id: organization, user_id: bob.id)).status.should eq(HTTP::Status::OK)
    bob_client.get(Accounts::Organizations::Index.path).json["organizations"].as_a.map(&.["name"]).should eq(["Bob Member"])
    expect_not_found(bob_client.post(Accounts::Organizations::Switch.path(organization_id: organization)))
  end
end

describe "roles" do
  it "keeps the choice per API token" do
    _, bob, organization, _, _ = two_users
    AccountsSpec.give(bob.id, :member, on: organization)
    token = Punch::Spec.bearer(Punch::Spec.api_token(bob.id))
    client = Punch::Spec.client
    client.post(Accounts::Organizations::Switch.path(organization_id: organization), headers: token).status.should eq(HTTP::Status::OK)
    client.get(Accounts::Organizations::Index.path, headers: token).json["organizations"][0]["current"].as_bool.should be_true
    Punch::Spec.client.sign_in(bob.id).get(Accounts::Organizations::Index.path).json["organizations"][0]["current"].as_bool.should be_false
  end
end
