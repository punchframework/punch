-- The language a user chose for the interface, as a locale tag such as
-- `de`. Without one, each request's Accept-Language decides.
ALTER TABLE users ADD COLUMN locale TEXT;
