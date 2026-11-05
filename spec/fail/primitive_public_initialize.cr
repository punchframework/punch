require "../../src/punch"

struct PublicNew
  include Punch::Primitive(String)

  def initialize(@value : String)
  end

  def self.parse(raw : String) : self | Punch::Invalid
    new(raw)
  end
end
