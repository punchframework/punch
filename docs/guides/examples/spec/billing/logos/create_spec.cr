require "../../spec_helper"

private PNG = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 7_u8)

private def uploaded(user : Accounts::Users::Record) : Punch::Upload::Grant
  Punch::Spec.uploads
  grant = Punch::Spec.db.write do |db|
    Punch::Upload.grant(db, Billing::Logos::Picture, size: PNG.size, content_type: "image/png", owner: user.id.to_s)
  end.as(Punch::Upload::Grant)
  Punch::Spec.upload(grant, PNG, Punch::Spec.db).should be_a(Punch::Upload::Checked)
  grant
end

describe Billing::Logos::Create do
  it "keeps an image with its size and alt text, and links to it" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    created = client.post(Billing::Logos::Create.path, json: {picture: uploaded(user).ticket.value, alt: "The mark", width: 320, height: 200})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["alt"].should eq("The mark")
    created.json["width"].should eq(320)
    logo = Punch::Spec.db.read { |db| Billing::Logos::Table.find(db, ExamplesSpec.parse(Billing::Logos::ID, 1_i64)) } || fail "no logo"
    {logo.image.width, logo.image.height, logo.image.scan_state, logo.image.delete_after}.should eq({320, 200, nil, nil})
  end

  it "refuses a side that cannot be, at the field" do
    user = AccountsSpec.user
    refused = Punch::Spec.client.sign_in(user.id).post(Billing::Logos::Create.path, json: {picture: uploaded(user).ticket.value, width: 0})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.json["errors"][0]["path"].should eq(JSON.parse(%(["picture"])))
    refused.json["errors"][0]["code"].should eq("out_of_range")
  end
end
