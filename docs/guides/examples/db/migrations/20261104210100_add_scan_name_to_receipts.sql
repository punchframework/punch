-- What a scan was called on the user's machine, to show and download under.
ALTER TABLE receipts ADD COLUMN scan_name TEXT NOT NULL DEFAULT 'scan';
