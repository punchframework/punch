require "../../src/punch"

# A converter writes JSON the derivation cannot know.
struct Stamped
  include JSON::Serializable

  @[JSON::Field(converter: Time::EpochConverter)]
  getter at : Time
end

Punch::JSONSchema.of(Stamped)
