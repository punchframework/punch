require "json"
require "uri"

module Punch::JSONSchema
  # One way a value fails a schema: where in the value (a JSON Pointer,
  # `/lines/2/amount`), which keyword, and why.
  record Violation, pointer : String, keyword : String, message : String do
    def to_s(io : IO) : Nil
      io << (pointer.empty? ? "(root)" : pointer) << ": " << message << " (" << keyword << ')'
    end
  end

  # Checks JSON values against the schemas Punch derives (JSON Schema
  # 2020-12): `type`, `enum`, `const`, `properties`, `required`,
  # `additionalProperties`, `items`, `prefixItems`, `minItems`, `maxItems`,
  # `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`,
  # `exclusiveMinimum`, `exclusiveMaximum`, `allOf`, `anyOf`, `oneOf`, `not`,
  # `$ref` within the document, and the formats Punch emits (`date-time`,
  # `int32`, `int64`). Other keywords are annotations and are ignored.
  # For specs: the contract check (`Punch::Spec::Client`) and payload
  # schemas; applications do not compile it.
  #
  # ```
  # Punch::JSONSchema.validate(JSON.parse(body), schema, root: document) # => [] of Violation
  # ```
  def self.validate(value : JSON::Any, schema : JSON::Any, root : JSON::Any = schema) : Array(Violation)
    violations = [] of Violation
    Validator.new(root, violations).check(value, schema, "")
    violations
  end

  # Not shared between threads: one per validation.
  private struct Validator
    MAX_DEPTH = 64

    def initialize(@root : JSON::Any, @violations : Array(Violation))
    end

    def check(value : JSON::Any, schema : JSON::Any, pointer : String, depth : Int32 = 0) : Nil
      raise ArgumentError.new("schema nests deeper than #{MAX_DEPTH} levels at #{pointer}; a $ref cycle without data?") if depth > MAX_DEPTH

      case keywords = schema.raw
      when Bool
        fail(pointer, "false", "no value is allowed here") unless keywords
        return
      when Hash(String, JSON::Any)
      else
        raise ArgumentError.new("not a schema at #{pointer}: #{schema.to_json}")
      end

      check_keywords(value, keywords, pointer, depth)
    end

    private def check_keywords(value : JSON::Any, keywords : Hash(String, JSON::Any), pointer : String, depth : Int32) : Nil
      if ref = keywords["$ref"]?
        check(value, resolve(ref.as_s), pointer, depth + 1)
      end
      return unless type?(value, keywords, pointer)

      if allowed = keywords["enum"]?
        fail(pointer, "enum", "#{value.to_json} is not one of #{allowed.to_json}") unless allowed.as_a.includes?(value)
      end
      if constant = keywords["const"]?
        fail(pointer, "const", "expected #{constant.to_json}, got #{value.to_json}") unless constant == value
      end

      case raw = value.raw
      when String                  then string(raw, keywords, pointer)
      when Int64, Float64          then number(raw, keywords, pointer)
      when Array(JSON::Any)        then array(raw, keywords, pointer, depth)
      when Hash(String, JSON::Any) then object(raw, keywords, pointer, depth)
      end

      combinators(value, keywords, pointer, depth)
    end

    # The `type` keyword; the other keywords are checked only after it
    # passed.
    private def type?(value : JSON::Any, keywords : Hash(String, JSON::Any), pointer : String) : Bool
      type = keywords["type"]? || return true
      names = type.as_a?.try(&.map(&.as_s)) || [type.as_s]
      return true if names.any? { |name| type?(value, name) }

      fail(pointer, "type", "expected #{names.join(" or ")}, got #{describe(value)}")
      false
    end

    private def string(value : String, keywords : Hash(String, JSON::Any), pointer : String) : Nil
      length = value.size
      if (min = keywords["minLength"]?.try(&.as_i64?)) && length < min
        fail(pointer, "minLength", "#{length} characters, at least #{min} expected")
      end
      if (max = keywords["maxLength"]?.try(&.as_i64?)) && length > max
        fail(pointer, "maxLength", "#{length} characters, at most #{max} expected")
      end
      if (pattern = keywords["pattern"]?.try(&.as_s?)) && !Regex.new(pattern).matches?(value)
        fail(pointer, "pattern", "#{value.inspect} does not match #{pattern}")
      end
      if keywords["format"]?.try(&.as_s?) == "date-time" && !date_time?(value)
        fail(pointer, "format", "#{value.inspect} is not an RFC 3339 date-time")
      end
    end

    private def number(value : Int64 | Float64, keywords : Hash(String, JSON::Any), pointer : String) : Nil
      bound(value, keywords, pointer, "minimum") { |limit| value >= limit }
      bound(value, keywords, pointer, "maximum") { |limit| value <= limit }
      bound(value, keywords, pointer, "exclusiveMinimum") { |limit| value > limit }
      bound(value, keywords, pointer, "exclusiveMaximum") { |limit| value < limit }

      case keywords["format"]?.try(&.as_s?)
      when "int32"
        fail(pointer, "format", "#{value} is outside int32") unless value.is_a?(Int64) && value >= Int32::MIN && value <= Int32::MAX
      when "int64"
        fail(pointer, "format", "#{value} is not an int64") unless value.is_a?(Int64)
      end
    end

    private def bound(value : Int64 | Float64, keywords : Hash(String, JSON::Any), pointer : String, keyword : String, & : Float64 -> Bool) : Nil
      limit = keywords[keyword]?.try { |any| any.as_i64?.try(&.to_f64) || any.as_f? } || return
      fail(pointer, keyword, "#{value} fails #{keyword} #{limit}") unless yield limit
    end

    private def array(items : Array(JSON::Any), keywords : Hash(String, JSON::Any), pointer : String, depth : Int32) : Nil
      if (min = keywords["minItems"]?.try(&.as_i64?)) && items.size < min
        fail(pointer, "minItems", "#{items.size} items, at least #{min} expected")
      end
      if (max = keywords["maxItems"]?.try(&.as_i64?)) && items.size > max
        fail(pointer, "maxItems", "#{items.size} items, at most #{max} expected")
      end
      prefix = keywords["prefixItems"]?.try(&.as_a) || [] of JSON::Any
      items.each_with_index do |item, index|
        schema = prefix[index]? || keywords["items"]? || next
        check(item, schema, "#{pointer}/#{index}", depth + 1)
      end
    end

    private def object(members : Hash(String, JSON::Any), keywords : Hash(String, JSON::Any), pointer : String, depth : Int32) : Nil
      keywords["required"]?.try &.as_a.each do |name|
        fail(pointer, "required", "#{name.as_s.inspect} is missing") unless members.has_key?(name.as_s)
      end
      properties = keywords["properties"]?.try(&.as_h)
      additional = keywords["additionalProperties"]?
      members.each do |name, member|
        child = "#{pointer}/#{escape(name)}"
        if schema = properties.try(&.[name]?)
          check(member, schema, child, depth + 1)
        elsif additional
          check(member, additional, child, depth + 1)
        end
      end
    end

    private def combinators(value : JSON::Any, keywords : Hash(String, JSON::Any), pointer : String, depth : Int32) : Nil
      keywords["allOf"]?.try &.as_a.each { |schema| check(value, schema, pointer, depth + 1) }
      if alternatives = keywords["anyOf"]?.try(&.as_a)
        unless alternatives.any? { |schema| passes?(value, schema, depth) }
          fail(pointer, "anyOf", "#{describe(value)} matches none of #{alternatives.size} alternatives")
        end
      end
      if alternatives = keywords["oneOf"]?.try(&.as_a)
        matched = alternatives.count { |schema| passes?(value, schema, depth) }
        fail(pointer, "oneOf", "#{describe(value)} matches #{matched} of #{alternatives.size} alternatives, exactly one expected") unless matched == 1
      end
      if (negated = keywords["not"]?) && passes?(value, negated, depth)
        fail(pointer, "not", "#{describe(value)} matches a schema it must not")
      end
    end

    private def passes?(value : JSON::Any, schema : JSON::Any, depth : Int32) : Bool
      violations = [] of Violation
      Validator.new(@root, violations).check(value, schema, "", depth + 1)
      violations.empty?
    end

    private def type?(value : JSON::Any, name : String) : Bool
      raw = value.raw

      case name
      when "null"    then raw.nil?
      when "boolean" then raw.is_a?(Bool)
      when "string"  then raw.is_a?(String)
      when "integer" then raw.is_a?(Int64) || (raw.is_a?(Float64) && raw == raw.trunc && raw.finite?)
      when "number"  then raw.is_a?(Int64) || raw.is_a?(Float64)
      when "array"   then raw.is_a?(Array)
      when "object"  then raw.is_a?(Hash)
      else                raise ArgumentError.new("unknown type #{name.inspect} in schema")
      end
    end

    # `#/components/schemas/Name`, or `#` for the root. Only references
    # into this document: Punch never emits others.
    private def resolve(ref : String) : JSON::Any
      raise ArgumentError.new("only references within the document are supported, got #{ref}") unless ref.starts_with?('#')
      ref[1..].split('/').reject(&.empty?).reduce(@root) do |node, token|
        token = URI.decode(token).gsub("~1", "/").gsub("~0", "~")
        node.as_h?.try(&.[token]?) || node.as_a?.try { |array| token.to_i?.try { |index| array[index]? } } ||
          raise ArgumentError.new("#{ref} does not resolve")
      end
    end

    private def date_time?(text : String) : Bool
      Time::Format::RFC_3339.parse(text)
      true
    rescue Time::Format::Error
      false
    end

    private def escape(name : String) : String
      name.gsub('~', "~0").gsub('/', "~1")
    end

    private def describe(value : JSON::Any) : String
      case value.raw
      when Nil     then "null"
      when Bool    then "boolean"
      when String  then "string"
      when Int64   then "integer"
      when Float64 then "number"
      when Array   then "array"
      else              "object"
      end
    end

    private def fail(pointer : String, keyword : String, message : String) : Nil
      @violations << Violation.new(pointer, keyword, message)
    end
  end
end
