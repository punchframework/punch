-- The outbox (docs/jobs.md): jobs a Command enqueues are written here in
-- its transaction and handed over to queue.db after the commit. The columns
-- are Punch's (Punch::Outbox.sql).
CREATE TABLE punch_outbox (
  id                INTEGER PRIMARY KEY,
  key               TEXT    NOT NULL UNIQUE,
  queue             TEXT    NOT NULL,
  type              TEXT    NOT NULL,
  version           INTEGER NOT NULL,
  payload           TEXT    NOT NULL,
  priority          INTEGER NOT NULL,
  run_at            INTEGER NOT NULL,
  max_attempts      INTEGER NOT NULL,
  concurrency_key   TEXT,
  concurrency_limit INTEGER,
  traceparent       TEXT,
  created_at        INTEGER NOT NULL,
  handed_over_at    INTEGER
) STRICT;

CREATE INDEX punch_outbox_pending ON punch_outbox (id) WHERE handed_over_at IS NULL;
CREATE INDEX punch_outbox_handed_over ON punch_outbox (handed_over_at) WHERE handed_over_at IS NOT NULL;

-- A sent invoice that came due gets one reminder (Billing::Invoices::Remind).
CREATE TABLE invoice_reminders (
  invoice_id INTEGER PRIMARY KEY REFERENCES invoices (id) ON DELETE CASCADE,
  created_at TEXT    NOT NULL
) STRICT;
