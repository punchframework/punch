require "../../src/punch"

struct Settings
  include Punch::Input
  getter options : Hash(String, String)
end

Settings.from_json("{}")
