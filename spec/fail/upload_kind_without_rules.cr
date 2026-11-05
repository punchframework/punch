require "../../src/punch"

struct Scan
  include Punch::Upload::Kind
end

Punch::Upload.kinds
