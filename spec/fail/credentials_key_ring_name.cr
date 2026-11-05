require "../../src/punch"

struct Settings
  include Punch::Credentials
  getter signing_keys : Punch::KeyRing
end

Settings.load(Punch::Credentials::Source.open("test", nil, {} of String => String))
