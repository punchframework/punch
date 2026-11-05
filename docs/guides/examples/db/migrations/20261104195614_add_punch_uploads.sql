-- Direct uploads (lib/punch/docs/uploads.md): each one granted, being checked, checked,
-- claimed by the app, or discarded. The columns are Punch's.
CREATE TABLE punch_uploads (
  id            TEXT    NOT NULL PRIMARY KEY,
  ticket_digest BLOB    NOT NULL UNIQUE,
  kind          TEXT    NOT NULL,
  owner         TEXT    NOT NULL,
  size          INTEGER NOT NULL,
  content_type  TEXT    NOT NULL,
  state         TEXT    NOT NULL CHECK (state IN ('granted', 'checking', 'checked', 'claimed', 'discarded')),
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER,
  claimed_at    INTEGER,
  checking_since INTEGER
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_uploads_owner ON punch_uploads (owner, state, expires_at);
CREATE INDEX punch_uploads_sweep ON punch_uploads (expires_at) WHERE expires_at IS NOT NULL;
