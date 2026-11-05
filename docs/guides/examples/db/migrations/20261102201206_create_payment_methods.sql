-- How a customer pays: a card or a bank transfer, one JSON document of
-- either shape (Billing::PaymentMethods::Method).
CREATE TABLE payment_methods (
  id             INTEGER PRIMARY KEY,
  customer_email TEXT    NOT NULL,
  method         TEXT    NOT NULL CHECK (json_valid(method) AND json_type(method) = 'object')
) STRICT;

CREATE INDEX payment_methods_customer ON payment_methods (customer_email);
