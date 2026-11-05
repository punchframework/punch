require "../../src/punch"

@[Punch::Upload::Rules(max_size: 10 * 1024 * 1024, types: ["image/png"])]
struct Photo
  include Punch::Upload::Kind
end

Punch::Upload.kinds
