require "../../spec_helper"

private PNG = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 7_u8)

private FILENAME = ExamplesSpec.parse(Punch::Upload::Filename, "Taxi Hamburg.png")

# A scan of *user*'s, granted and sent to the storage, as a browser does.
private def uploaded(user : Accounts::Users::Record) : Punch::Upload::Grant
  Punch::Spec.uploads
  grant = Punch::Spec.db.write do |db|
    Punch::Upload.grant(db, Billing::Receipts::Scan, size: PNG.size, content_type: "image/png", owner: user.id.to_s, filename: FILENAME)
  end.as(Punch::Upload::Grant)
  Punch::Spec.upload(grant, PNG, Punch::Spec.db).should be_a(Punch::Upload::Checked)
  grant
end

describe Billing::Receipts::UploadScan do
  it "grants an upload the kind's rules allow" do
    Punch::Spec.uploads
    client = AccountsSpec.client
    granted = client.post(Billing::Receipts::UploadScan.path, json: {size: 2_000, content_type: "image/png"})
    granted.status.should eq(HTTP::Status::CREATED)
    granted.json["method"].should eq("PUT")
    granted.json["headers"]["Content-Length"].should eq("2000")

    named = client.post(Billing::Receipts::UploadScan.path, json: {size: 2_000, content_type: "image/png", filename: "C:\\fakepath\\scan.png"})
    named.status.should eq(HTTP::Status::CREATED)
  end

  it "refuses a file the kind does not take, at the field" do
    Punch::Spec.uploads
    client = AccountsSpec.client
    refused = client.post(Billing::Receipts::UploadScan.path, json: {size: 20_000_000, content_type: "image/gif"})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.json["errors"].as_a.map(&.["code"]).should eq(["too_large", "unsupported_type"])
  end
end

describe Billing::Receipts::Create do
  it "saves a receipt with the scan its ticket names, once" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    grant = uploaded(user)

    created = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["receipt"]["scan_type"].should eq("image/png")
    created.json["receipt"]["scan_size"].should eq(PNG.size)
    created.json["receipt"]["scan_name"].should eq("Taxi Hamburg.png")

    again = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    again.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    again.json["errors"][0]["code"].should eq("upload_not_found")
  end

  it "refuses another user's ticket" do
    grant = uploaded(AccountsSpec.user)
    refused = AccountsSpec.client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value})
    refused.json["errors"][0]["path"].should eq(JSON.parse(%(["scan"])))
    refused.json["errors"][0]["code"].should eq("upload_not_found")
  end
end

describe Billing::Receipts::ShowPage do
  it "shows the scan's link to the user who keeps it, and to no one else" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    grant = uploaded(user)
    id = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value}).json["receipt"]["id"]
    receipt_id = ExamplesSpec.parse(Billing::Receipts::ID, id.as_i64)

    client.get(Billing::Receipts::ShowPage.href(receipt_id: receipt_id).to_s, headers: HTTP::Headers{"Accept" => "text/html"})
      .should have_element("a", text: "Taxi Hamburg.png")
    AccountsSpec.client.get(Billing::Receipts::Show.path(receipt_id: receipt_id)).status.should eq(HTTP::Status::NOT_FOUND)
  end
end

describe Billing::Receipts::Destroy do
  it "gives up the scan with the receipt" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    grant = uploaded(user)
    id = client.post(Billing::Receipts::Create.path, json: {description: "Taxi", scan: grant.ticket.value}).json["receipt"]["id"]
    receipt_id = ExamplesSpec.parse(Billing::Receipts::ID, id.as_i64)

    client.delete(Billing::Receipts::Destroy.path(receipt_id: receipt_id)).status.should eq(HTTP::Status::NO_CONTENT)
    client.get(Billing::Receipts::Show.path(receipt_id: receipt_id)).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
