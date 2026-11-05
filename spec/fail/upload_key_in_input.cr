require "../../src/punch"

struct Detach
  include Punch::Input

  getter scan : Punch::Upload::Key
end

Detach.from_json(%({"scan": "scans/aaaaaaaaaaaaaaaaaaaaaaaaaa"}))
