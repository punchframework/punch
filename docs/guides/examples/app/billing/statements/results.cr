module Billing::Statements
  # A statement as the API shows it to the user who keeps it: `filename` is
  # decrypted here, and `url` saves the file under a plain name, so the real
  # one is in no link. `Create` does not answer with this: a client's
  # idempotency key would keep the name and the link in plaintext.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    filename : Punch::Upload::Filename,
    url : String? do
    include JSON::Serializable

    def self.of(statement : Record) : self
      new(statement.id, statement.file.filename.unwrap, Punch::Upload.url?(statement.file, download: true))
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end
end
