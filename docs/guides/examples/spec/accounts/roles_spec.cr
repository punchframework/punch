require "../spec_helper"

describe "roles" do
  it "opens the ops console to operators and hides it from everyone else" do
    operator = AccountsSpec.operator
    other = AccountsSpec.client
    operator.visit(Punch::Ops::Console::IndexPage.href).status.should eq(HTTP::Status::OK)
    operator.visit(Home::IndexPage.href).should have_element("nav a", text: "Ops")
    other.visit(Punch::Ops::Console::IndexPage.href).status.should eq(HTTP::Status::NOT_FOUND)
    other.visit(Home::IndexPage.href).should_not have_element("nav a", text: "Ops")
  end
end
