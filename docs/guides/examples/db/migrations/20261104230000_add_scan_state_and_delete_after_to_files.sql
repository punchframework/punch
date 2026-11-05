-- Kept files say what a scan found and when they may go. A receipt's scan
-- moves to the prefix file_, so its columns read file_scan_state.
ALTER TABLE receipts RENAME COLUMN scan_key TO file_key;
ALTER TABLE receipts RENAME COLUMN scan_filename TO file_filename;
ALTER TABLE receipts RENAME COLUMN scan_size TO file_size;
ALTER TABLE receipts RENAME COLUMN scan_content_type TO file_content_type;
ALTER TABLE receipts ADD COLUMN file_scan_state TEXT;
ALTER TABLE receipts ADD COLUMN file_delete_after TEXT;
ALTER TABLE statements ADD COLUMN file_scan_state TEXT;
ALTER TABLE statements ADD COLUMN file_delete_after TEXT;
