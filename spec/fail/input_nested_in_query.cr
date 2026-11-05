require "../../src/punch"

struct Line
  include Punch::Input
  getter cents : Int64
end

struct Create
  include Punch::Input
  getter lines : Array(Line)
end

Create.from_query(URI::Params.new)
