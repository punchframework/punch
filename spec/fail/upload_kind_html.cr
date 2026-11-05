require "../../src/punch"

@[Punch::Upload::Rules(max_size: 1_000_000, types: ["image/png", "text/html"])]
struct Page
  include Punch::Upload::Kind
end

Punch::Upload.kinds
