require "../../src/punch"

struct Settings
  include Punch::Credentials
  getter smtp : Punch::Secret(Smtp)

  struct Smtp
    include Punch::Credentials
    getter host : String
  end
end

Settings.load(Punch::Credentials::Source.open("test", nil, {} of String => String))
