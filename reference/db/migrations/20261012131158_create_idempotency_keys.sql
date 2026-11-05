-- Idempotency keys (docs/operations.md): the stored answer of a Command per
-- caller, operation, and key. The columns are Punch's
-- (Punch::IdempotencyKeys.sql).
CREATE TABLE punch_idempotency_keys (
  scope        TEXT    NOT NULL,
  operation    TEXT    NOT NULL,
  key          TEXT    NOT NULL,
  fingerprint  BLOB    NOT NULL,
  status       INTEGER NOT NULL,
  content_type TEXT,
  location     TEXT,
  body         BLOB    NOT NULL,
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  PRIMARY KEY (scope, operation, key)
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_idempotency_keys_expiry ON punch_idempotency_keys (expires_at);
