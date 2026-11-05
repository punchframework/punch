require "json"
require "uri"

module Punch::Input
  # Reads one value of a field's type from JSON or from a string (path and
  # query parameters). One overload per supported type; everything returns the
  # value, an `Invalid` for this value, or `Failed` when errors deeper down
  # (array elements, nested inputs) were already recorded.
  #
  # Every JSON reader consumes exactly one value, also when it fails, so that
  # parsing continues with the next field and all errors are collected.
  module Read
    # Errors below this value were recorded in the collector already.
    struct Failed
    end

    INTEGER = /\A-?(?:0|[1-9][0-9]*)\z/
    NUMBER  = /\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/

    def self.json(type : String.class, pull : JSON::PullParser, errors : Rejection::Collector) : String | Invalid
      return skip(pull, "expected_string") unless pull.kind.string?

      string(String, pull.read_string)
    end

    def self.json(type : Bool.class, pull : JSON::PullParser, errors : Rejection::Collector) : Bool | Invalid
      pull.kind.bool? ? pull.read_bool : skip(pull, "expected_boolean")
    end

    def self.json(type : Int32.class, pull : JSON::PullParser, errors : Rejection::Collector) : Int32 | Invalid
      integer(Int32, pull)
    end

    def self.json(type : Int64.class, pull : JSON::PullParser, errors : Rejection::Collector) : Int64 | Invalid
      integer(Int64, pull)
    end

    def self.json(type : Float64.class, pull : JSON::PullParser, errors : Rejection::Collector) : Float64 | Invalid
      return skip(pull, "expected_number") unless pull.kind.int? || pull.kind.float?

      raw = pull.raw_value
      pull.read_next
      float(raw)
    end

    def self.json(type : Time.class, pull : JSON::PullParser, errors : Rejection::Collector) : Time | Invalid
      return skip(pull, "expected_string") unless pull.kind.string?

      string(Time, pull.read_string)
    end

    def self.json(type : Array(T).class, pull : JSON::PullParser, errors : Rejection::Collector) : Array(T) | Invalid | Failed forall T
      return skip(pull, "expected_array") unless pull.kind.begin_array?

      items = [] of T
      failed = false
      index = 0
      pull.read_array do
        case item = json(T, pull, errors.nested(index))
        in Invalid
          errors.add(index, item)
          failed = true
        in Failed
          failed = true
        in T
          items << item
        end

        index += 1
      end
      failed ? Failed.new : items
    end

    # Enums, domain primitives, and nested inputs.
    def self.json(type : T.class, pull : JSON::PullParser, errors : Rejection::Collector) forall T
      {% if T < Enum %}
        return skip(pull, "expected_string") unless pull.kind.string?

        string(T, pull.read_string)
      {% elsif T < Punch::Input %}
        return skip(pull, "expected_object") unless pull.kind.begin_object?

        T.__punch_read_json(pull, errors)
      {% elsif T < Punch::TypedID %}
        if T.public_prefix
          return skip(pull, "expected_string") unless pull.kind.string?

          T.parse(pull.read_string)
        else
          case raw = json(Int64, pull, errors)
          in Invalid then raw
          in Int64   then T.parse(raw)
          end
        end
      {% else %}
        {% primitive = T.ancestors.find { |a| a.name(generic_args: false) == "Punch::Primitive" } %}
        {% raise "Punch::Input cannot read #{T} from JSON" unless primitive %}
        case raw = json({{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, pull, errors)
        in Invalid then raw
        in {{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then T.parse(raw)
        end
      {% end %}
    end

    # From path and query parameters. Booleans are `true` and `false`; numbers
    # use the JSON number grammar.
    def self.string(type : String.class, raw : String) : String | Invalid
      raw.valid_encoding? ? raw : Invalid.new("invalid_encoding")
    end

    def self.string(type : Bool.class, raw : String) : Bool | Invalid
      case raw
      when "true"  then true
      when "false" then false
      else              Invalid.new("expected_boolean")
      end
    end

    def self.string(type : Int32.class, raw : String) : Int32 | Invalid
      return Invalid.new("expected_integer") unless INTEGER.matches?(raw)

      raw.to_i32? || Invalid.new("out_of_range", min: Int32::MIN, max: Int32::MAX)
    end

    def self.string(type : Int64.class, raw : String) : Int64 | Invalid
      return Invalid.new("expected_integer") unless INTEGER.matches?(raw)

      raw.to_i64? || Invalid.new("out_of_range", min: Int64::MIN, max: Int64::MAX)
    end

    def self.string(type : Float64.class, raw : String) : Float64 | Invalid
      float(raw)
    end

    # RFC 3339 with a time zone offset, such as `2026-10-08T09:30:00Z`.
    def self.string(type : Time.class, raw : String) : Time | Invalid
      Time.parse_rfc3339(raw)
    rescue Time::Format::Error | ArgumentError
      # ArgumentError: a well-formed date that does not exist (February 30).
      Invalid.new("invalid_date_time")
    end

    def self.string(type : T.class, raw : String) forall T
      {% if T < Enum %}
        {% raise "Punch::Input does not read flags enums such as #{T}" if T.annotation(Flags) %}
        T.each { |member| return member if member.to_s.underscore == raw }
        Invalid.new("invalid_choice")
      {% elsif T < Punch::TypedID %}
        if T.public_prefix
          T.parse(raw)
        else
          case value = string(Int64, raw)
          in Invalid then value
          in Int64   then T.parse(value)
          end
        end
      {% else %}
        {% primitive = T.ancestors.find { |a| a.name(generic_args: false) == "Punch::Primitive" } %}
        {% raise "Punch::Input cannot read #{T} from a path or query parameter" unless primitive %}
        case value = string({{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, raw)
        in Invalid then value
        in {{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then T.parse(value)
        end
      {% end %}
    end

    private def self.integer(type : T.class, pull : JSON::PullParser) : T | Invalid forall T
      if pull.kind.int?
        raw = pull.raw_value
        pull.read_next
        string(T, raw)
      else
        skip(pull, "expected_integer")
      end
    end

    private def self.float(raw : String) : Float64 | Invalid
      return Invalid.new("expected_number") unless NUMBER.matches?(raw)

      value = raw.to_f64?
      value && value.finite? ? value : Invalid.new("out_of_range")
    end

    private def self.skip(pull : JSON::PullParser, code : String) : Invalid
      pull.skip
      Invalid.new(code)
    end
  end
end
