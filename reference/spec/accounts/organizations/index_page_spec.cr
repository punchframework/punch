require "../../spec_helper"

# Two users, each administrator of an organization of their own, and
# clients signed in as them.
private def two_users
  ada, bob = AccountsSpec.user("Ada Admin"), AccountsSpec.user("Bob Member")
  organization = Punch::Spec.db.read { |db| AccountsSpec.organization(db, ada.id) }
  {ada, bob, organization, Punch::Spec.client.sign_in(ada.id), Punch::Spec.client.sign_in(bob.id)}
end

describe "organization pages" do
  it "shows where the user works, lets them switch, and starts an organization" do
    _, bob, organization, _, bob_client = two_users
    AccountsSpec.give(bob.id, :member, on: organization)
    page = bob_client.visit(Accounts::Organizations::IndexPage.href)
    page.should have_element("header", text: /in Bob Member/)
    page.should have_element("table.organizations tr", text: /Bob Member.*working here/)
    page.should have_element("button", text: "Work here", count: 1)
    page.should have_element("a[href='#{Accounts::Organizations::Members::IndexPage.href(organization_id: organization).url}']")

    bob_client.submit(Accounts::Organizations::Switch.action(organization_id: organization))
      .should redirect_to(Home::IndexPage.href)
    bob_client.visit(Home::IndexPage.href).should have_element("header", text: /in Ada Admin/)

    bob_client.submit(Accounts::Organizations::Create.action, form: {"name" => "Side Project"})
      .should redirect_to(Home::IndexPage.href)
    bob_client.visit(Home::IndexPage.href).should have_element("header", text: /in Side Project/)
  end
end
