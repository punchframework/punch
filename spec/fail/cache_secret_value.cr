require "../../src/punch"

struct Credentials
  include JSON::Serializable
  getter user : String
  getter tokens : Array(Punch::Secret(String))?
end

TOKENS = Punch::Cache(String, Credentials).new("tokens", ttl: 1.minute)
TOKENS.clear
