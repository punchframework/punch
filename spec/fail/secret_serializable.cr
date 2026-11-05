require "json"
require "../../src/punch"

struct Payload
  include JSON::Serializable
  getter token : Punch::Secret(String)

  def initialize(@token)
  end
end

Payload.new(Punch::Secret.new("sk_live_123")).to_json
