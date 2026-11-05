-- A receipt's scan is one Punch::Upload::File: its columns take the group's
-- names (scan_key, scan_filename, scan_size, scan_content_type).
ALTER TABLE receipts RENAME COLUMN scan TO scan_key;
ALTER TABLE receipts RENAME COLUMN scan_name TO scan_filename;
ALTER TABLE receipts RENAME COLUMN scan_type TO scan_content_type;
