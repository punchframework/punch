-- Email identities and passwords (docs/auth.md): how users are known and
-- how they prove it, kept out of the users table. The columns are Punch's;
-- the references to users are the app's.
CREATE TABLE punch_email_identities (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email       TEXT    NOT NULL UNIQUE,
  verified_at TEXT,
  created_at  TEXT    NOT NULL
) STRICT;

CREATE INDEX punch_email_identities_by_user ON punch_email_identities (user_id);

CREATE TABLE punch_passwords (
  user_id    INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  hash       TEXT    NOT NULL,
  created_at TEXT    NOT NULL,
  updated_at TEXT    NOT NULL
) STRICT;
