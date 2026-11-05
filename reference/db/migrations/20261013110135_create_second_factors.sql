-- Second factors (docs/auth.md): authenticator apps and their recovery
-- codes. The secret and unseen codes are encrypted with the key ring; codes
-- in use are SHA-256 digests. The columns are Punch's; the references to
-- users are the app's.
CREATE TABLE punch_totp_authenticators (
  user_id      INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  secret       BLOB    NOT NULL,
  confirmed_at TEXT,
  last_step    INTEGER NOT NULL,
  unseen_codes BLOB,
  created_at   TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_recovery_codes (
  code_hash  BLOB    PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_recovery_codes_by_user ON punch_recovery_codes (user_id);
