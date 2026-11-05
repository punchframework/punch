-- Progress of jobs that run in steps (lib/punch/docs/jobs.md, "Long jobs: steps"),
-- written in the steps' own transactions. The columns are Punch's.
CREATE TABLE punch_job_progress (
  key         TEXT    PRIMARY KEY,
  type        TEXT    NOT NULL,
  step        TEXT,
  cursor      TEXT,
  saves       INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  finished_at INTEGER
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_job_progress_finished ON punch_job_progress (finished_at) WHERE finished_at IS NOT NULL;
