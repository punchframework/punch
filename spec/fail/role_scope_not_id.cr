require "../../src/punch"

struct Member
  include Punch::Role
  scope String
  permits Member
end
