-- The language a customer's mail is written in, as a locale tag such as
-- `de`. Without one, the language of the user who owns the customer, else
-- the app's default.
ALTER TABLE customers ADD COLUMN locale TEXT;
