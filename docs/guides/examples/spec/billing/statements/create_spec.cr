require "../../spec_helper"

private PDF = "%PDF-1.7\n%âãÏÓ\n1 0 obj\n".to_slice

private FILENAME = ExamplesSpec.parse(Punch::Upload::Filename, "Statement Ada Lovelace.pdf")

private def uploaded(user : Accounts::Users::Record) : Punch::Upload::Grant
  Punch::Spec.uploads
  grant = Punch::Spec.db.write do |db|
    Punch::Upload.grant(db, Billing::Statements::Document, size: PDF.size, content_type: "application/pdf", owner: user.id.to_s, filename: FILENAME)
  end.as(Punch::Upload::Grant)
  Punch::Spec.upload(grant, PDF, Punch::Spec.db).should be_a(Punch::Upload::Checked)
  grant
end

describe Billing::Statements::Create do
  it "keeps the file's name encrypted, and shows it only to the user who keeps it" do
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    created = client.post(Billing::Statements::Create.path, json: {document: uploaded(user).ticket.value})
    created.status.should eq(HTTP::Status::CREATED)
    created.body.should_not contain("Ada")

    stored = Punch::Spec.db.read { |db| db.query_one?("SELECT file_filename FROM statements", &.read(Bytes)) }
    stored.should be_encrypted_for("statements", "file_filename")
    id = ExamplesSpec.parse(Billing::Statements::ID, created.json["id"].as_i64)
    client.get(Billing::Statements::Show.path(statement_id: id)).json["filename"].should eq("Statement Ada Lovelace.pdf")
    AccountsSpec.client.get(Billing::Statements::Show.path(statement_id: id)).status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "reads a private file back whole, with no name in its link" do
    user = AccountsSpec.user
    Punch::Spec.client.sign_in(user.id).post(Billing::Statements::Create.path, json: {document: uploaded(user).ticket.value})
    statement = Punch::Spec.db.read { |db| Billing::Statements::Table.find(db, ExamplesSpec.parse(Billing::Statements::ID, 1_i64)) } || fail "no statement"
    statement.file.filename.unwrap.should eq(FILENAME)
    statement.file.content_type.should eq("application/pdf")
    Punch::Upload.href(statement.file).to_s.should_not contain("Ada")
    statement.file.filename.to_s.should eq("[REDACTED]")
  end
end
