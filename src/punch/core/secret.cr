require "crypto/subtle"

module Punch
  # A value that must not leak: a credential, a token, a decrypted column.
  # It prints as `[REDACTED]` in `to_s`, `inspect`, string interpolation,
  # and therefore logs and error reports. Serializing it to JSON or YAML
  # does not compile, so it cannot slip into a response, a job payload, or
  # an event. `unwrap` is the one explicit way to the value.
  #
  # ```
  # key = Punch::Secret.new(ENV["STRIPE_KEY"])
  # "#{key}"    # => "[REDACTED]"
  # key.unwrap  # => the string itself
  # key.to_json # compile error
  # ```
  #
  # Limits: Crystal strings are immutable and garbage collected, so the value
  # is not wiped from memory, and `unwrap` hands out an ordinary value that
  # can be logged by mistake. The wrapper prevents accidents, not attacks on
  # the process.
  struct Secret(T)
    REDACTED = "[REDACTED]"

    def initialize(@value : T)
    end

    # The value itself. Call it at the point of use, never earlier.
    def unwrap : T
      @value
    end

    # Applies the block to the value and keeps the result secret.
    def map(& : T -> U) : Secret(U) forall U
      Secret.new(yield @value)
    end

    # Compares in constant time for `String` and `Bytes`, so a comparison does
    # not reveal how much of a guess was right.
    def ==(other : Secret(T)) : Bool
      Secret.equal?(@value, other.unwrap)
    end

    # Hashing would make the value guessable through `Hash` timing and is not
    # needed: secrets are not keys.
    def hash(hasher)
      {% raise "Punch::Secret cannot be hashed or used as a Hash key." %}
    end

    def to_s(io : IO) : Nil
      io << REDACTED
    end

    def inspect(io : IO) : Nil
      io << "Punch::Secret(" << REDACTED << ')'
    end

    def to_json(*args, **options)
      {% raise "Punch::Secret cannot be serialized to JSON. Call `unwrap` explicitly if the value really must leave the process (lib/punch/docs/core-types.md)." %}
    end

    def to_yaml(*args, **options)
      {% raise "Punch::Secret cannot be serialized to YAML. Call `unwrap` explicitly if the value really must leave the process (lib/punch/docs/core-types.md)." %}
    end

    protected def self.equal?(a : String, b : String) : Bool
      ::Crypto::Subtle.constant_time_compare(a, b)
    end

    protected def self.equal?(a : Bytes, b : Bytes) : Bool
      ::Crypto::Subtle.constant_time_compare(a, b)
    end

    protected def self.equal?(a, b) : Bool
      a == b
    end
  end
end
