require "../../../spec_helper"

private def expect_forbidden(response : Punch::Spec::Response) : Nil
  {response.status, response.json["code"]}.should eq({HTTP::Status::FORBIDDEN, "forbidden"})
end

# Two users, each administrator of an organization of their own, and
# clients signed in as them.
private def two_users
  ada, bob = AccountsSpec.user("Ada Admin"), AccountsSpec.user("Bob Member")
  organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, ada.id) }
  {ada, bob, organization, Punch::Spec.client.sign_in(ada.id), Punch::Spec.client.sign_in(bob.id)}
end

private def verified(user : Accounts::Users::Record, email : String) : Nil
  Punch::Spec.db.write { |db| Punch::Auth::EmailIdentities.add(db, user.id, InvoicingSpec.parse(Punch::Email, email), verified_at: Time.utc) }
end

describe "roles" do
  it "keeps the last administrator, and lets members leave" do
    ada, bob, organization, ada_client, bob_client = two_users
    verified(ada, "ada@example.org")
    members = Accounts::Organizations::Members::Create.path(organization_id: organization)
    demoted = ada_client.post(members, json: {email: "ada@example.org", role: "member"})
    {demoted.status, demoted.json["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "last_administrator"})
    left = ada_client.delete(Accounts::Organizations::Members::Destroy.path(organization_id: organization, user_id: ada.id))
    left.json["code"].should eq("last_administrator")

    AccountsSpec.give(bob.id, :member, on: organization)
    expect_forbidden(bob_client.delete(Accounts::Organizations::Members::Destroy.path(organization_id: organization, user_id: ada.id)))
    left = bob_client.delete(Accounts::Organizations::Members::Destroy.path(organization_id: organization, user_id: bob.id))
    left.json["left"].as_bool.should be_true

    # With a second administrator, the first may step down.
    AccountsSpec.give(bob.id, :administrator, on: organization)
    ada_client.post(members, json: {email: "ada@example.org", role: "member"}).json["role"].should eq("member")
  end
end
