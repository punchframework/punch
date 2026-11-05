require "../../src/punch"

@[Punch::Status(201)]
struct Missing
  include Punch::Problem
end
