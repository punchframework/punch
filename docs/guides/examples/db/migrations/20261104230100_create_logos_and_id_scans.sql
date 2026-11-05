-- A logo is an image anyone may see; an ID scan is a private image, whose
-- name and alt text are encrypted (BLOB), and which is scanned before use.
CREATE TABLE logos (
  id                 INTEGER PRIMARY KEY,
  user_id            INTEGER NOT NULL REFERENCES users (id),
  image_key          TEXT    NOT NULL,
  image_filename     TEXT    NOT NULL,
  image_size         INTEGER NOT NULL,
  image_content_type TEXT    NOT NULL,
  image_scan_state   TEXT,
  image_delete_after TEXT,
  image_width        INTEGER,
  image_height       INTEGER,
  image_alt          TEXT
) STRICT;

CREATE INDEX logos_by_user ON logos (user_id);

CREATE TABLE id_scans (
  id                 INTEGER PRIMARY KEY,
  user_id            INTEGER NOT NULL REFERENCES users (id),
  photo_key          TEXT    NOT NULL,
  photo_filename     BLOB    NOT NULL,
  photo_size         INTEGER NOT NULL,
  photo_content_type TEXT    NOT NULL,
  photo_scan_state   TEXT,
  photo_delete_after TEXT,
  photo_width        INTEGER,
  photo_height       INTEGER,
  photo_alt          BLOB
) STRICT;

CREATE INDEX id_scans_by_user ON id_scans (user_id);
