require "../../src/punch"

struct Settings
  include Punch::Credentials
  getter host : String?
end

Punch.credentials Settings, environments: %w[development Production]
