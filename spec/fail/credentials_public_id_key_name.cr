require "../../src/punch"

struct Settings
  include Punch::Credentials
  getter ids_key : Punch::PublicIDKey?
end

Settings.load(Punch::Credentials::Source.open("test", nil, {} of String => String))
