require "../../src/punch"

struct NoParse
  include Punch::Primitive(String)
end
