require "json"

module Punch
  # A domain primitive: a value that has been parsed and cannot exist unparsed,
  # such as an `Email` instead of a `String` that should be one.
  #
  # Rules, checked by the compiler once the including type is complete:
  # 1. The type defines `self.parse`, returning `self | Punch::Invalid`.
  # 2. `initialize` is private, so `.parse` is the only way in.
  #
  # ```
  # struct InvoiceNumber
  #   include Punch::Primitive(String)
  #
  #   def self.parse(raw : String) : self | Punch::Invalid
  #     return Punch::Invalid.new("invalid_invoice_number") unless raw.matches?(/\AINV-\d{6}\z/)
  #     new(raw)
  #   end
  #
  #   # Optional: JSON Schema keywords added to the stored type's schema.
  #   def self.json_schema
  #     {pattern: "^INV-[0-9]{6}$"}
  #   end
  # end
  # ```
  #
  # `include` provides `value`, a private constructor taking it, `to_s`,
  # `to_json` (the value), and equality and hashing by value. Equality between two different primitive
  # types is always false.
  module Primitive(T)
    getter value : T

    private def initialize(@value : T)
    end

    def ==(other : self) : Bool
      value == other.value
    end

    def hash(hasher)
      value.hash(hasher)
    end

    def to_s(io : IO) : Nil
      value.to_s(io)
    end

    # Serializes as its value: `"ann@example.org"`, `42`.
    def to_json(json : JSON::Builder) : Nil
      value.to_json(json)
    end

    # As a key of a JSON object (a composite's map, docs/composites.md):
    # its text, as `to_s` writes it.
    def to_json_object_key : String
      to_s
    end

    # The stored type `T` of a primitive type, for code outside the module.
    def self.stored_type(type : U.class) forall U
      {{ U.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" }.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
    end

    macro included
      # Reads the value back through `parse`, so JSON cannot build a
      # primitive that `parse` would refuse: for cached values and, later,
      # job payloads. A refused value raises `JSON::ParseException`.
      def self.new(pull : ::JSON::PullParser) : self
        line, column = pull.location
        parsed = parse(Punch::Primitive.stored_type(self).new(pull))
        raise ::JSON::ParseException.new("#{self}: #{parsed.code}", line, column) if parsed.is_a?(Punch::Invalid)
        parsed
      end

      macro finished
        \{% unless @type.abstract? || @type.class.has_method?("parse") %}
          \{% raise "#{@type} includes Punch::Primitive but defines no `self.parse`. A domain primitive is created only by parsing (lib/punch/docs/core-types.md)." %}
        \{% end %}
        \{% for method in @type.methods %}
          \{% if method.name == "initialize" && method.visibility != :private %}
            \{% raise "#{@type}#initialize must be private: a domain primitive is created only by `self.parse` (lib/punch/docs/core-types.md)." %}
          \{% end %}
        \{% end %}
      end
    end
  end
end
