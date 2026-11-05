-- What the app sells, priced per unit in each currency it is sold in.
-- The pricing is one JSON document (Billing::Products::Pricing), kept an
-- object by its CHECK.
CREATE TABLE products (
  id      INTEGER PRIMARY KEY,
  name    TEXT    NOT NULL UNIQUE,
  pricing TEXT    NOT NULL CHECK (json_valid(pricing) AND json_type(pricing) = 'object')
) STRICT;
