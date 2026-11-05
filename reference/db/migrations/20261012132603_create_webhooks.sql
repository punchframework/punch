-- Inbound webhooks (docs/webhooks.md): each delivery as received, and where
-- its processing is. The columns are Punch's
-- (Punch::Webhook::Invocations.sql).
CREATE TABLE punch_webhooks (
  id          INTEGER PRIMARY KEY,
  provider    TEXT    NOT NULL,
  key         TEXT    NOT NULL,
  fingerprint BLOB    NOT NULL,
  state       TEXT    NOT NULL,
  body        BLOB    NOT NULL,
  headers     TEXT    NOT NULL,
  attempts    INTEGER NOT NULL,
  error       TEXT,
  received_at INTEGER NOT NULL,
  verified_at INTEGER,
  finished_at INTEGER,
  UNIQUE (provider, key)
) STRICT;

CREATE INDEX punch_webhooks_by_state ON punch_webhooks (provider, state);
CREATE INDEX punch_webhooks_finished ON punch_webhooks (finished_at) WHERE finished_at IS NOT NULL;
