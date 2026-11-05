require "../../src/punch"

# A client must not name the state of its own file.
struct Scanned
  include Punch::Input

  getter state : Punch::Upload::ScanState
end

Scanned.from_json(%({"state": "clean"}))
