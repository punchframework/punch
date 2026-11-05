-- The outbox: jobs written in a Command's transaction, handed over
-- to queue.db after the commit (lib/punch/docs/jobs.md). The columns are Punch's.
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
