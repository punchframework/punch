-- punch_uploads keeps a file's name until it is claimed.
ALTER TABLE punch_uploads ADD COLUMN filename TEXT;
