require "../../spec_helper"

private PNG = "\x89PNG\r\n\x1A\n".to_slice + Bytes.new(24, 7_u8)

private FILENAME = ExamplesSpec.parse(Punch::Upload::Filename, "ID Ada Lovelace.png")

private def uploaded(user : Accounts::Users::Record) : Punch::Upload::Grant
  Punch::Spec.uploads
  grant = Punch::Spec.db.write do |db|
    Punch::Upload.grant(db, Billing::IdScans::Photo, size: PNG.size, content_type: "image/png", owner: user.id.to_s, filename: FILENAME)
  end.as(Punch::Upload::Grant)
  Punch::Spec.upload(grant, PNG, Punch::Spec.db).should be_a(Punch::Upload::Checked)
  grant
end

# What the app's scanning job does when it has a result.
private def scanned(state : Punch::Upload::ScanState) : Nil
  Punch::Spec.db.write do |db|
    scan = Billing::IdScans::Table.find(db, ExamplesSpec.parse(Billing::IdScans::ID, 1_i64)) || fail "no scan"
    Punch.cannot_violate(Billing::IdScans::Table.update(db, scan.copy_with(photo: scan.photo.scanned(state))))
  end
end

describe Billing::IdScans::Create do
  it "starts pending with no link, and encrypts the name and the alt text" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    created = client.post(Billing::IdScans::Create.path, json: {photo: uploaded(user).ticket.value, alt: "Ada's passport"})
    created.status.should eq(HTTP::Status::CREATED)
    created.json["id_scan"]["state"].should eq("pending")
    created.json["id_scan"]["url"]?.should be_nil
    created.body.should_not contain("Ada")

    stored = Punch::Spec.db.read { |db| db.query_one?("SELECT photo_filename, photo_alt FROM id_scans") { |row| {row.read(Bytes), row.read(Bytes)} } }
    name, alt = stored || fail "no scan"
    name.should be_encrypted_for("id_scans", "photo_filename")
    alt.should be_encrypted_for("id_scans", "photo_alt")
  end

  it "links only once the scan passed it, and never with the name" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    client.post(Billing::IdScans::Create.path, json: {photo: uploaded(user).ticket.value})
    show = Billing::IdScans::Show.path(id_scan_id: ExamplesSpec.parse(Billing::IdScans::ID, 1_i64))

    scanned(Punch::Upload::ScanState::QUARANTINED)
    client.get(show).json["url"]?.should be_nil

    scanned(Punch::Upload::ScanState::CLEAN)
    answer = client.get(show)
    answer.json["state"].should eq("clean")
    answer.json["url"].as_s.should_not contain("Ada")
  end
end
