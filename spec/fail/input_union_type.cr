require "../../src/punch"

struct Amount
  include Punch::Input
  getter value : Int32 | String
end

Amount.from_json("{}")
