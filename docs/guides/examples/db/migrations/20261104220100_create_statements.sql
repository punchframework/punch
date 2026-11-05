-- Bank statements their users keep. The name of a statement's file often
-- holds the account holder's, so it is encrypted: a Punch::Upload::PrivateFile,
-- whose filename column is a BLOB.
CREATE TABLE statements (
  id                INTEGER PRIMARY KEY,
  user_id           INTEGER NOT NULL REFERENCES users (id),
  file_key          TEXT    NOT NULL,
  file_filename     BLOB    NOT NULL,
  file_size         INTEGER NOT NULL,
  file_content_type TEXT    NOT NULL,
  created_at        TEXT    NOT NULL
) STRICT;

CREATE INDEX statements_by_user ON statements (user_id);
