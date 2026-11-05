require "../../src/punch"

PRICES = Punch::Cache(Float64, String).new("prices", ttl: 1.minute)
PRICES.clear
