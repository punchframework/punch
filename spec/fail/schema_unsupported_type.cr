require "../../src/punch"

# A type that is neither a value Punch knows, an input, nor serializable.
class Plain
end

Punch::JSONSchema.of(Plain)
