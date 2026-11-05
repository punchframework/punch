-- Converting customers.email, last of three releases: the plaintext column
-- goes. The release before neither read nor wrote it, and
-- `punch db:encrypt` cleared it, so it holds only NULLs. The customer email
-- is now customers.email_encrypted, found through email_index.
-- rebuild: customers
ALTER TABLE customers DROP COLUMN email;
