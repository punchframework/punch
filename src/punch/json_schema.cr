require "json"

module Punch
  # JSON Schema (draft 2020-12) derived from Crystal types: the one
  # derivation behind the OpenAPI document, and later job payload locks,
  # forms, and action blocks. It describes exactly what Punch reads and
  # writes:
  #
  # - **Inputs** (`Punch::Input`): the fields of the body or query string.
  #   A field is required unless it is nilable or has a default; only
  #   nilable fields accept `null`. Path parameters are left out of the
  #   object and listed by `fields`.
  # - **Outputs** (`JSON::Serializable`): instance variables under their JSON
  #   keys, honouring `@[JSON::Field(key:, ignore:, emit_null:)]`.
  # - **Values**: `String`, `Bool`, `Int32`, `Int64`, `Float64`, `Time`
  #   (RFC 3339), enums (snake_case names), domain primitives (the stored
  #   type plus the primitive's own `json_schema` keywords), `Array`,
  #   `Hash(String, T)`, and unions.
  #
  # Objects and enums are named and defined once in a `Registry`; everything
  # else is inline. Derivation runs in one small method per type, and only
  # for types something asks about, so it costs nothing in a build that does
  # not use it.
  #
  # ```
  # Punch::JSONSchema.of(Send::Input) # => {"$schema" => …, "$ref" => …, "$defs" => {…}}
  # ```
  module JSONSchema
    DIALECT = "https://json-schema.org/draft/2020-12/schema"

    # One field of an input: where it comes from and its schema. *nested*:
    # a nested input, which a query string carries in brackets.
    record Field, name : String, schema : JSON::Any, required : Bool, path : Bool, nested : Bool = false

    # Named schemas. Each object or enum type is defined once, under a name
    # made from its Crystal name (`Billing::Invoices::Send::Input` becomes
    # `Billing.Invoices.Send.Input`), and referenced by `$ref` everywhere
    # else. Not shared between threads: one registry per derivation.
    class Registry
      # Prepended to names in `$ref`: `#/$defs/` for a standalone schema,
      # `#/components/schemas/` for OpenAPI.
      getter prefix : String

      # Schema name to Crystal type name, for descriptions added later.
      getter type_names = {} of String => String

      # Schema name to its properties' Crystal field names, where a JSON key
      # differs from or stands for a getter: descriptions come from getters.
      getter field_names = {} of String => Hash(String, String)

      # Whether objects are described as stored payloads are read: a field
      # is required unless it is nilable or has a default, as
      # `JSON::Serializable` parses it, rather than whenever `to_json`
      # always writes it.
      getter? payloads : Bool

      @definitions = {} of String => JSON::Any

      def initialize(@prefix : String = "#/$defs/", *, @payloads : Bool = false)
      end

      # The schema of *type*: inline, or a reference to its definition.
      def schema(type : T.class) : JSON::Any forall T
        JSONSchema.derive(type, self)
      end

      # Defines the schema built by the block under the name of
      # *type_name*, once, and returns a reference to it. Recursive types
      # work: the name is taken before the block runs.
      def define(type_name : String, & : -> JSON::Any) : JSON::Any
        name = JSONSchema.name(type_name)
        if existing = @type_names[name]?
          raise ArgumentError.new("#{type_name} and #{existing} both have the schema name #{name}") unless existing == type_name
        else
          @type_names[name] = type_name
          @definitions[name] = JSON::Any.new(nil)
          @definitions[name] = yield
        end
        JSONSchema.object({"$ref" => JSON::Any.new(prefix + name)})
      end

      # Every definition, sorted by name, so documents are stable.
      def definitions : Hash(String, JSON::Any)
        @definitions.keys.sort!.to_h { |name| {name, @definitions[name]} }
      end
    end

    # A standalone schema of *type*, with the named parts under `$defs`.
    def self.of(type : T.class) : JSON::Any forall T
      registry = Registry.new
      root = registry.schema(type).as_h.dup
      document = {"$schema" => JSON::Any.new(DIALECT)}
      document.merge!(root)
      definitions = registry.definitions
      document["$defs"] = JSON::Any.new(definitions) unless definitions.empty?
      JSON::Any.new(document)
    end

    # The fields of an input, path parameters included, in declaration
    # order. OpenAPI turns them into parameters; forms into controls.
    def self.fields(type : T.class, registry : Registry) : Array(Field) forall T
      {% raise "#{T} is not a Punch::Input" unless T < Punch::Input %}
      fields = [] of Field
      {% for ivar in T.instance_vars %}
        {% name = ivar.name.stringify %}
        %schema = registry.schema({{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        {% default = ivar.default_value %}
        {% if ivar.has_default_value? && (default.is_a?(NumberLiteral) || default.is_a?(StringLiteral) || default.is_a?(BoolLiteral)) %}
          %schema = set(%schema, "default", JSON.parse({{ default }}.to_json))
        {% elsif ivar.has_default_value? && default.is_a?(Call) && ivar.type.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
          %schema = set(%schema, "default", JSON.parse(({{ default }}).to_json))
        {% elsif ivar.has_default_value? && default.is_a?(Path) && ivar.type.union_types.any? { |member| member < Enum } %}
          %schema = set(%schema, "default", JSON::Any.new({{ default.names.last.stringify.underscore }}))
        {% end %}
        fields << Field.new({{ name }}, %schema,
          {{ !ivar.type.nilable? && !ivar.has_default_value? }},
          {{ !!ivar.annotation(Punch::PathParam) }},
          {{ ivar.type.union_types.any? { |member| member < Punch::Input } }})
      {% end %}
      fields
    end

    # --- Values ----------------------------------------------------------

    def self.derive(type : String.class, registry : Registry) : JSON::Any
      typed("string")
    end

    def self.derive(type : Bool.class, registry : Registry) : JSON::Any
      typed("boolean")
    end

    def self.derive(type : Int32.class, registry : Registry) : JSON::Any
      typed("integer", {"format" => JSON::Any.new("int32")})
    end

    def self.derive(type : Int64.class, registry : Registry) : JSON::Any
      typed("integer", {"format" => JSON::Any.new("int64")})
    end

    def self.derive(type : Float64.class, registry : Registry) : JSON::Any
      typed("number", {"format" => JSON::Any.new("double")})
    end

    def self.derive(type : Time.class, registry : Registry) : JSON::Any
      typed("string", {"format" => JSON::Any.new("date-time")})
    end

    def self.derive(type : Nil.class, registry : Registry) : JSON::Any
      typed("null")
    end

    def self.derive(type : Array(T).class, registry : Registry) : JSON::Any forall T
      typed("array", {"items" => registry.schema(T)})
    end

    def self.derive(type : Hash(String, T).class, registry : Registry) : JSON::Any forall T
      typed("object", {"additionalProperties" => registry.schema(T)})
    end

    # A composite's map with domain keys: the keys' schema as `propertyNames`.
    def self.derive(type : Hash(K, V).class, registry : Registry) : JSON::Any forall K, V
      {% raise "Hash(#{K}, #{V}) has no JSON Schema: a key is a String or a domain primitive stored as String" unless K.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
      typed("object", {"propertyNames" => registry.schema(K), "additionalProperties" => registry.schema(V)})
    end

    # A field of an encrypted composite, inside the document's ciphertext:
    # what the payload lock records. A result cannot hold one
    # (`Punch::Secret#to_json` does not compile).
    def self.derive(type : Secret(T).class, registry : Registry) : JSON::Any forall T
      registry.schema(T)
    end

    # Unions, enums, domain primitives, inputs, and serializable objects.
    def self.derive(type : T.class, registry : Registry) : JSON::Any forall T
      {% if T.union? %}
        {% members = T.union_types.reject { |member| member == Nil } %}
        {% if members.size == 1 %}
          nullable(registry.schema({{ members.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}))
        {% elsif members.all? { |member| member < Punch::Composite } && !T.nilable? %}
          # A polymorphic composite: one of its members, named by their key.
          %members = [{% for member in members %} registry.schema({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}), {% end %}] of JSON::Any
          one_of(%members, {{ members.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_DISCRIMINATOR)
        {% else %}
          object({"anyOf" => JSON::Any.new([{% for member in T.union_types %} registry.schema({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}), {% end %}] of JSON::Any)})
        {% end %}
      {% elsif T < Enum %}
        {% raise "#{T} is a flags enum, which has no JSON Schema in Punch" if T.annotation(Flags) %}
        registry.define({{ T.name.stringify }}) do
          typed("string", {"enum" => JSON::Any.new(T.values.map { |member| JSON::Any.new(member.to_s.underscore) })})
        end
      {% elsif primitive = T.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
        primitive(T, {{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, registry)
      {% elsif T < Punch::Composite %}
        T.punch_schema(registry)
      {% elsif T < Punch::Input %}
        registry.define({{ T.name.stringify }}) { input(fields(T, registry), registry, name({{ T.name.stringify }})) }
      {% elsif T < JSON::Serializable %}
        registry.define({{ T.name.stringify }}) { serializable(T, registry, name({{ T.name.stringify }})) }
      {% else %}
        {% raise "#{T} has no JSON Schema. Use String, Bool, Int32, Int64, Float64, Time, an enum, a domain primitive, an Array, a Hash(String, T), a Punch::Input, or a type that includes JSON::Serializable." %}
      {% end %}
    end

    # The stored type's schema plus the primitive's own keywords: a
    # primitive can define `self.json_schema`, returning a NamedTuple such as
    # `{format: "idn-email", maxLength: 254}`.
    private def self.primitive(type : T.class, stored : S.class, registry : Registry) : JSON::Any forall T, S
      klass = T
      # A public typed ID travels as text, though stored as a number; stored
      # payloads keep the number (`Punch::Stored.json`).
      if !registry.payloads? && klass.responds_to?(:public_pattern)
        return set(registry.schema(String), "pattern", JSON::Any.new(klass.public_pattern))
      end

      schema = registry.schema(S)
      if klass.responds_to?(:json_schema)
        klass.json_schema.each { |key, value| schema = set(schema, key.to_s, JSON.parse(value.to_json)) }
      end
      schema
    end

    # The body or query fields of an input, without path parameters.
    # Not generic: built once for all inputs from their fields.
    private def self.input(fields : Array(Field), registry : Registry, schema_name : String) : JSON::Any
      properties = {} of String => JSON::Any
      required = [] of JSON::Any
      sources = registry.field_names[schema_name] = {} of String => String
      fields.each do |field|
        next if field.path
        properties[field.name] = field.schema
        sources[field.name] = field.name
        required << JSON::Any.new(field.name) if field.required
      end
      object_schema(properties, required)
    end

    # The JSON `to_json` writes: keys, ignored fields, and `emit_null`.
    private def self.serializable(type : T.class, registry : Registry, schema_name : String) : JSON::Any forall T
      properties = {} of String => JSON::Any
      required = [] of JSON::Any
      sources = registry.field_names[schema_name] = {} of String => String
      {% for ivar in T.instance_vars %}
        {% field = ivar.annotation(JSON::Field) %}
        {% unless field && (field[:ignore] || field[:ignore_serialize]) %}
          {% raise "#{T}##{ivar.name} has a JSON converter, so its schema cannot be derived" if field && field[:converter] %}
          {% key = (field && field[:key]) || ivar.name.stringify %}
          properties[{{ key }}] = registry.schema({{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
          sources[{{ key }}] = {{ ivar.name.stringify }}
          {% if !ivar.type.nilable? || (field && field[:emit_null]) %}
            required << JSON::Any.new({{ key }}) unless registry.payloads? && {{ ivar.type.nilable? || ivar.has_default_value? }}
          {% end %}
        {% end %}
      {% end %}
      object_schema(properties, required)
    end

    # --- Helpers ---------------------------------------------------------

    # The schema name of a Crystal type: `::` becomes `.`, and anything
    # outside `A-Z a-z 0-9 . _ -` becomes `_` (OpenAPI component names).
    def self.name(type_name : String) : String
      type_name.gsub("::", ".").gsub(/[^A-Za-z0-9._-]+/, "_").strip('_')
    end

    # Allows `null` as well: in `type` where there is one, otherwise as an
    # alternative.
    def self.nullable(schema : JSON::Any) : JSON::Any
      hash = schema.as_h
      if (type = hash["type"]?) && (name = type.as_s?)
        set(schema, "type", JSON::Any.new([JSON::Any.new(name), JSON::Any.new("null")]))
      else
        object({"anyOf" => JSON::Any.new([schema, typed("null")])})
      end
    end

    # *schema* with *key* set to *value*.
    def self.set(schema : JSON::Any, key : String, value : JSON::Any) : JSON::Any
      hash = schema.as_h.dup
      hash[key] = value
      JSON::Any.new(hash)
    end

    def self.object(hash : Hash(String, JSON::Any)) : JSON::Any
      JSON::Any.new(hash)
    end

    private def self.typed(type : String, keywords : Hash(String, JSON::Any) = {} of String => JSON::Any) : JSON::Any
      hash = {"type" => JSON::Any.new(type)}
      hash.merge!(keywords)
      JSON::Any.new(hash)
    end

    # A composite's object (docs/composites.md): its declared fields.
    def self.composite(properties : Hash(String, JSON::Any), required : Array(String)) : JSON::Any
      object_schema(properties, required.map { |name| JSON::Any.new(name) })
    end

    # *schema* of an array (`maxItems`) or map (`maxProperties`) with at
    # most *max* elements.
    def self.bounded(schema : JSON::Any, keyword : String, max : Int32) : JSON::Any
      set(schema, keyword, JSON::Any.new(max.to_i64))
    end

    # A polymorphic composite: one of its members, named by *key*.
    def self.one_of(members : Array(JSON::Any), key : String) : JSON::Any
      object({"oneOf" => JSON::Any.new(members), "discriminator" => object({"propertyName" => JSON::Any.new(key)})})
    end

    private def self.object_schema(properties : Hash(String, JSON::Any), required : Array(JSON::Any)) : JSON::Any
      schema = {"type" => JSON::Any.new("object"), "properties" => JSON::Any.new(properties)}
      schema["required"] = JSON::Any.new(required) unless required.empty?
      JSON::Any.new(schema)
    end
  end
end
