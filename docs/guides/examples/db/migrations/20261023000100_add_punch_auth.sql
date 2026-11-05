-- Auth::Sessions, API tokens, one-time tokens, email identities,
-- passwords, and second factors (lib/punch/docs/auth.md). The columns are Punch's; the
-- references to users are the app's.
CREATE TABLE punch_sessions (
  id               INTEGER PRIMARY KEY,
  token_hash       BLOB    NOT NULL UNIQUE,
  user_id          INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  method           TEXT    NOT NULL,
  authenticated_at TEXT    NOT NULL,
  created_at       TEXT    NOT NULL,
  last_seen_at     TEXT    NOT NULL,
  expires_at       TEXT    NOT NULL,
  ip               TEXT,
  user_agent       TEXT
) STRICT;

CREATE INDEX punch_sessions_by_user ON punch_sessions (user_id);

CREATE TABLE punch_api_tokens (
  id           INTEGER PRIMARY KEY,
  token_hash   BLOB    NOT NULL UNIQUE,
  user_id      INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name         TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  expires_at   TEXT    NOT NULL,
  last_used_at TEXT
) STRICT;

CREATE INDEX punch_api_tokens_by_user ON punch_api_tokens (user_id);

CREATE TABLE punch_one_time_tokens (
  token_hash BLOB    PRIMARY KEY,
  purpose    TEXT    NOT NULL,
  user_id    INTEGER REFERENCES users (id) ON DELETE CASCADE,
  subject    TEXT,
  created_at TEXT    NOT NULL,
  expires_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_one_time_tokens_by_user ON punch_one_time_tokens (user_id, purpose);

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
