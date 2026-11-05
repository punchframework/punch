require "../../src/punch"

struct Show
  include Punch::Input

  @[Punch::PathParam]
  getter slug : Punch::Slug?
end

Show.from_query(URI::Params.new, {"slug" => "a"})
