require "../../src/punch"

LOOKUPS = Punch::Cache(String | Int64, String).new("lookups", ttl: 1.minute)
LOOKUPS.clear
