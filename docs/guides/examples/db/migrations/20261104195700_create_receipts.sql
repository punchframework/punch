-- Receipts their users keep: what each one was for, and the key of its
-- scan in object storage (Billing::Receipts).
CREATE TABLE receipts (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users (id),
  description TEXT    NOT NULL,
  scan        TEXT    NOT NULL,
  scan_size   INTEGER NOT NULL,
  scan_type   TEXT    NOT NULL,
  created_at  TEXT    NOT NULL
) STRICT;

CREATE INDEX receipts_by_user ON receipts (user_id);
