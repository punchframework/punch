require "../../spec_helper"

describe "API tokens" do
  it "are revoked by their owner, after which they are refused" do
    user = AccountsSpec.user
    token = Punch::Spec.api_token(user.id)
    agent = Punch::Spec.bearer(token)
    client = Punch::Spec.client.sign_in(user.id)
    id = client.get(Accounts::Tokens::Index.path).json["tokens"][0]["id"].as_i64
    revoked = client.submit(Accounts::Tokens::Destroy.action(token_id: id))
    revoked.should redirect_to(Accounts::Tokens::IndexPage.href)
    Punch::Spec.client.get(Accounts::Tokens::Index.path, headers: agent).status.should eq(HTTP::Status::UNAUTHORIZED)
  end

  it "of another user are not found" do
    owner = AccountsSpec.user
    Punch::Spec.api_token(owner.id)
    id = Punch::Spec.db.read { |db| Punch::Auth::APITokens.list(db, owner.id.value).first.id }
    stranger = Punch::Spec.client.sign_in(AccountsSpec.user("Stranger").id)
    stranger.delete(Accounts::Tokens::Destroy.path(token_id: id)).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
