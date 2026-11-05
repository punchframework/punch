require "../../src/punch"

struct Member
  include Punch::Role
  permits String
end

Punch::Roles.definitions
