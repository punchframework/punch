require "../../src/punch"

struct Settings
  include Punch::Credentials
  getter hosts : Array(String)
end

Settings.load(Punch::Credentials::Source.open("test", nil, {} of String => String))
