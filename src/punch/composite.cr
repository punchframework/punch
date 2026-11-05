require "json"

module Punch
  # Declares a composite: a value type made of named fields, stored on a
  # row either as a group of prefixed columns or as one JSON document
  # (docs/composites.md). `punch db:generate` reads the declaration with
  # Crystal's parser and writes the struct; this macro expands to nothing.
  #
  # ```
  # Punch.composite Billing::Address,
  #   street: Punch::NonEmptyString,
  #   postal_code: Billing::PostalCode,
  #   city: Punch::NonEmptyString,
  #   country: {type: Punch::NonEmptyString, default: "DE"}
  # ```
  #
  # The macro's own parameter has a name no field can have, so a field
  # called `name` is a field.
  macro composite(__name, **fields)
  end

  # Included by every struct `punch db:generate` writes for a
  # `Punch.composite` (docs/composites.md). The functions here are what
  # the generated code calls: reading and writing the stored document,
  # bounds, the composite's own `check`, defaults, and versions.
  #
  # A composite is always parsed: it has no public constructor, `build`
  # and `copy_with` return `self | Punch::Invalid`, and a stored value
  # that does not parse raises `Punch::Database::RowError` with the path
  # of the field, never the value.
  module Composite
    # The key of a stored document's version, absent for version 1.
    VERSION_KEY = "$v"

    # The default bound of a document's size, in bytes of its JSON text.
    MAX_BYTES = 16 * 1024

    # The default bound of a document's nesting: objects and arrays inside
    # each other, the document itself counting as 1. A composite raises it
    # with `max_depth:`, up to `DEPTH_LIMIT`, below the depth at which
    # Crystal's JSON builder refuses to write (99), so a document that
    # reads can always be written back with the keys it carried.
    MAX_DEPTH   = 32
    DEPTH_LIMIT = 64

    # The keys of a stored document that this release does not declare,
    # kept so that writing the document back does not lose them.
    alias UnknownKeys = Hash(String, JSON::Any)

    # A stored document, or a part of one, that does not parse: at *path*
    # (`$.lines[2].amount`), for *reason* (an `Invalid` code or one of
    # Punch's: `missing`, `not_string`, `too_many`, `newer_version`, …).
    # Turned into a `Database::RowError` or a `JSON::ParseException` where
    # the document came from.
    class Unreadable < Exception
      getter path : String
      getter reason : String

      def initialize(@path : String, @reason : String)
        super("#{path}: #{reason}")
      end
    end

    macro included
      # Reads the stored form, as `Punch::Stored.json` writes it (job
      # payloads, cached values): parsed like a column, never trusted.
      def self.new(pull : ::JSON::PullParser) : self
        ::Punch::Composite.from_json(self, pull)
      end
    end

    # *value* with its bounds and the composite's own rules checked: what
    # `build` and `copy_with` return. A composite that defines
    # `self.check(value : self) : Punch::Invalid?` refuses a combination of
    # fields there (`valid_from < valid_until`).
    def self.checked(value : T) : T | Invalid forall T
      {% if T.has_method?("punch_bounds") %}
        if invalid = value.punch_bounds
          return invalid
        end
      {% end %}
      {% if T.class.has_method?("check") %}
        if invalid = T.check(value)
          return invalid
        end
      {% end %}
      size = begin
        dump(value).bytesize
      rescue JSON::Error # a Float64 field that is not finite: JSON has no such number
        return Invalid.new("not_finite")
      end
      return Invalid.new("too_large", max: T::PUNCH_MAX_BYTES) if size > T::PUNCH_MAX_BYTES

      value
    end

    # *value* read from a group of columns starting with *prefix*, with the
    # composite's own rules checked; a refusal is the row's.
    def self.grouped(value : T, table : String, prefix : String, row_id : Int64?) : T forall T
      {% if T.class.has_method?("check") %}
        if invalid = T.check(value)
          raise Database::RowError.new(table, "#{prefix}*", row_id, T.name, invalid.code)
        end
      {% end %}
      value
    end

    # Whether every column of a nilable group is NULL: then it is absent.
    def self.absent?(*values) : Bool
      values.all?(Nil)
    end

    # The value of a required column of a nilable group that is there: a
    # NULL means the row holds only part of the group.
    def self.present(value : V?, table : String, column : String, row_id : Int64?) : V forall V
      value.nil? ? raise Database::RowError.new(table, column, row_id, "a group of columns", "partial_group") : value
    end

    # *value* read from a document, with the composite's own rules
    # checked; a refusal is the document's, at *path*.
    def self.verified(value : T, path : String) : T forall T
      {% if T.class.has_method?("check") %}
        if invalid = T.check(value)
          raise Unreadable.new(path, invalid.code)
        end
      {% end %}
      value
    end

    # The stored form of *value*: a JSON object with its version when not
    # 1, its declared fields (`nil` ones left out), and the keys it was read
    # with that this release does not know.
    def self.dump(value : Composite) : String
      JSON.build { |json| value.punch_store(json) }
    end

    # Parses the stored document *raw* of *table*.*column* into *type*;
    # anything that does not parse raises `Database::RowError` naming the
    # row and the path, never the value.
    def self.load(type : T.class, raw : String, table : String, column : String, row_id : Int64?) : T forall T
      if raw.bytesize > max_bytes(T)
        raise Database::RowError.new(table, column, row_id, T.name, "too_large")
      end
      document(T, raw)
    rescue ex : Unreadable
      raise Database::RowError.new(table, column, row_id, T.name, ex.reason, ex.path)
    end

    # The largest document *type* reads: its own bound, or for a
    # polymorphic composite (a union of members) the largest member's.
    def self.max_bytes(type : T.class) : Int32 forall T
      {% if T.union? %}
        { {% for member in T.union_types %} {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_MAX_BYTES, {% end %} }.max
      {% else %}
        T::PUNCH_MAX_BYTES
      {% end %}
    end

    # The deepest document *type* reads: its own bound, or for a
    # polymorphic composite the deepest member's.
    def self.max_depth(type : T.class) : Int32 forall T
      {% if T.union? %}
        { {% for member in T.union_types %} {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_MAX_DEPTH, {% end %} }.max
      {% else %}
        T::PUNCH_MAX_DEPTH
      {% end %}
    end

    # Parses a document's text, raising `Unreadable`: `too_deep` past the
    # composite's nesting bound, which the parser enforces as it goes, so a
    # deep document costs no deep recursion.
    def self.document(type : T.class, raw : String) : T forall T
      pull = JSON::PullParser.new(raw)
      any = parse(pull, max_depth(T))
      raise Unreadable.new("$", "not_json") unless pull.kind.eof?

      value(T, any, "$")
    rescue JSON::ParseException
      raise Unreadable.new("$", "not_json")
    end

    # Reads stored JSON of a composite (`Punch::Stored.from_json`: job
    # payloads, cached values). Anything else is refused: a composite is
    # stored data, and outside stored JSON a typed ID would have to be in
    # its public form.
    # :nodoc:
    def self.from_json(type : T.class, pull : JSON::PullParser) : T forall T
      line, column = pull.location
      raise Unreadable.new("$", "not_stored_json") unless Stored.storing?

      value(T, parse(pull, max_depth(T)), "$")
    rescue ex : Unreadable
      raise JSON::ParseException.new("#{T}: #{ex.message}", line || 0, column || 0)
    end

    # The next JSON value of *pull*, refusing what two parsers could read
    # differently or that nests too deep: an object with a key twice
    # (`duplicate_key`; SQLite's paths read the first, a hash the last),
    # and nesting past *max_depth* (`too_deep`), checked before descending.
    def self.parse(pull : JSON::PullParser, max_depth : Int32, depth : Int32 = 0) : JSON::Any
      case pull.kind
      when .begin_array?
        raise Unreadable.new("$", "too_deep") if depth >= max_depth
        list = [] of JSON::Any
        pull.read_array { list << parse(pull, max_depth, depth + 1) }
        JSON::Any.new(list)
      when .begin_object?
        raise Unreadable.new("$", "too_deep") if depth >= max_depth
        object = {} of String => JSON::Any
        pull.read_object do |key|
          raise Unreadable.new("$", "duplicate_key") if object.has_key?(key)
          object[key] = parse(pull, max_depth, depth + 1)
        end
        JSON::Any.new(object)
      else
        JSON::Any.new(pull)
      end
    end

    # --- Reading -------------------------------------------------------------

    # The field *key* of *object*: required unless *type* is nilable.
    def self.read(object : Hash(String, JSON::Any), key : String, type : T.class, path : String, *, max : Int32? = nil) : T forall T
      any = object[key]?
      if any.nil? || any.raw.nil?
        {% if T.nilable? %}
          return nil
        {% else %}
          raise Unreadable.new(field_path(path, key), "missing")
        {% end %}
      end
      value(T, any, field_path(path, key), max)
    end

    # The field *key* of *object*, or *default* when the key is missing:
    # a field added with a default needs no new version.
    def self.read(object : Hash(String, JSON::Any), key : String, type : T.class, path : String, default : T, *, max : Int32? = nil) : T forall T
      any = object[key]?
      return default if any.nil? || any.raw.nil?

      value(T, any, field_path(path, key), max)
    end

    # The keys of *object* outside *known* and the version, if any.
    def self.unknown(object : Hash(String, JSON::Any), known : Tuple) : UnknownKeys?
      extra = nil
      object.each do |key, value|
        next if key == VERSION_KEY || known.includes?(key)
        (extra ||= UnknownKeys.new)[key] = value
      end
      extra
    end

    # The version a stored object says it has: 1 without `$v`.
    def self.version(object : Hash(String, JSON::Any), path : String) : Int32
      any = object[VERSION_KEY]? || return 1
      version = any.raw.as?(Int64)
      raise Unreadable.new(field_path(path, VERSION_KEY), "not_integer") unless version && 1 <= version <= 1000

      version.to_i32
    end

    # An object of a version this binary does not read: newer than its
    # own (written by a newer release, then rolled back), or older than
    # its oldest frozen type.
    def self.unreadable_version(current : Int32, version : Int32, path : String) : NoReturn
      raise Unreadable.new(path, version > current ? "newer_version" : "unknown_version")
    end

    # Reads an older version with its frozen type (`Punch::Payloads::Frozen`)
    # and upgrades it, step by step, to *type*.
    def self.frozen(type : T.class, frozen : V.class, object : Hash(String, JSON::Any), path : String) : T forall T, V
      old = begin
        Stored.from_json(V, object.to_json)
      rescue JSON::ParseException
        raise Unreadable.new(path, "not_frozen_shape")
      end
      upgrade(T, old, path)
    end

    # Converts *value* to *type* through each `upgrade`; one that returns
    # `Punch::Invalid` makes the document unreadable.
    def self.upgrade(type : T.class, value : V, path : String) : T forall T, V
      {% if V == T %}
        value
      {% else %}
        case next_value = value.upgrade
        when Invalid then raise Unreadable.new(path, next_value.code)
        else              upgrade(T, next_value, path)
        end
      {% end %}
    end

    # The member named by *key* of a polymorphic composite's object.
    def self.tag(object : Hash(String, JSON::Any), key : String, path : String) : String
      object[key]?.try(&.as_s?) || raise Unreadable.new(field_path(path, key), "missing")
    end

    # :nodoc:
    def self.unknown_member(path : String, key : String) : NoReturn
      raise Unreadable.new(field_path(path, key), "unknown_member")
    end

    def self.value(type : String.class, any : JSON::Any, path : String, max : Int32? = nil) : String
      any.as_s? || raise Unreadable.new(path, "not_string")
    end

    def self.value(type : Int64.class, any : JSON::Any, path : String, max : Int32? = nil) : Int64
      any.raw.as?(Int64) || raise Unreadable.new(path, "not_integer")
    end

    def self.value(type : Float64.class, any : JSON::Any, path : String, max : Int32? = nil) : Float64
      case raw = any.raw
      when Float64 then raw
      when Int64   then raw.to_f64
      else              raise Unreadable.new(path, "not_real")
      end
    end

    def self.value(type : Bool.class, any : JSON::Any, path : String, max : Int32? = nil) : Bool
      raw = any.raw
      raise Unreadable.new(path, "not_boolean") unless raw.is_a?(Bool)

      raw
    end

    def self.value(type : Time.class, any : JSON::Any, path : String, max : Int32? = nil) : Time
      text = any.as_s? || raise Unreadable.new(path, "not_string")
      Time.parse_rfc3339(text).to_utc
    rescue Time::Format::Error | ArgumentError | Time::Location::InvalidTimezoneOffsetError
      raise Unreadable.new(path, "invalid_time")
    end

    def self.value(type : Array(E).class, any : JSON::Any, path : String, max : Int32? = nil) : Array(E) forall E
      list = any.as_a? || raise Unreadable.new(path, "not_array")
      raise Unreadable.new(path, "too_many") if max && list.size > max

      list.map_with_index { |element, index| value(E, element, "#{path}[#{index}]") }
    end

    def self.value(type : Hash(K, V).class, any : JSON::Any, path : String, max : Int32? = nil) : Hash(K, V) forall K, V
      object = any.as_h? || raise Unreadable.new(path, "not_object")
      raise Unreadable.new(path, "too_many") if max && object.size > max

      # An entry is named by its position, never its key: keys are data.
      object.each_with_index.to_h { |(key, element), index| {map_key(K, key, "#{path}{#{index}}"), value(V, element, "#{path}{#{index}}")} }
    end

    def self.value(type : Secret(T).class, any : JSON::Any, path : String, max : Int32? = nil) : Secret(T) forall T
      Secret.new(value(T, any, path))
    end

    # Nilable fields, polymorphic composites, domain primitives, and
    # composites.
    def self.value(type : T.class, any : JSON::Any, path : String, max : Int32? = nil) : T forall T
      {% if T.nilable? %}
        {% inner = T.union_types.reject { |member| member == Nil } %}
        {% if inner.size == 1 %}
          any.raw.nil? ? nil : value({{ inner.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, any, path, max)
        {% else %}
          any.raw.nil? ? nil : value(::Union({{ inner.map(&.stringify.gsub(::Punch::NAME_STARTS, "::")).join(", ").id }}), any, path, max)
        {% end %}
      {% elsif T.union? %}
        {% inner = T.union_types %}
        {% raise "#{T}: a composite's field is one type, optionally nilable, or a polymorphic composite" unless inner.all? { |member| member < ::Punch::Composite } %}
        object = any.as_h? || raise Unreadable.new(path, "not_object")
        key = {{ inner.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_DISCRIMINATOR
        case tag(object, key, path)
        {% for member in inner %}
          when {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_TAG
            {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.punch_parse(object, path)
        {% end %}
        else unknown_member(path, key)
        end
      {% elsif T < ::Punch::Composite %}
        object = any.as_h? || raise Unreadable.new(path, "not_object")
        T.punch_parse(object, path)
      {% elsif primitive = T.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
        case parsed = T.parse(value({{ primitive.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, any, path))
        in Invalid then raise Unreadable.new(path, parsed.code)
        in T       then parsed
        end
      {% else %}
        {% raise "#{T} cannot be a composite's field: use a domain primitive, Time, Bool, Int64, Float64, String, a composite, or a bounded Array or Hash of them (lib/punch/docs/composites.md)" %}
      {% end %}
    end

    # A map's key: `String`, or a domain primitive stored as `String`.
    private def self.map_key(type : String.class, key : String, path : String) : String
      key
    end

    private def self.map_key(type : K.class, key : String, path : String) : K forall K
      case parsed = K.parse(key)
      in Invalid then raise Unreadable.new(path, "invalid_key")
      in K       then parsed
      end
    end

    # `$.address`, or `$.notes["two words"]` for a declared key that is not
    # a name. Only declared keys go into a path; a map's entries are named
    # by position, `$.prices{2}`.
    def self.field_path(path : String, key : String) : String
      key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? "#{path}.#{key}" : "#{path}[#{key.inspect}]"
    end

    # Counts each composite object in the stored document *any* by its
    # name and the version it was written in (`db:audit`), so a frozen
    # type can go once no row of its version is left. Follows the current
    # declaration; parts an older version kept elsewhere are not counted.
    def self.versions(type : T.class, any : JSON::Any, counts : Hash(String, Int64)) : Nil forall T
      {% if T.nilable? || (T.union? && T.union_types.all? { |member| member < ::Punch::Composite }) %}
        {% members = T.union_types.reject { |member| member == Nil } %}
        object = any.as_h? || return
        {% if members.size == 1 %}
          versions({{ members.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, any, counts)
        {% else %}
          tag = object[{{ members.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_DISCRIMINATOR]?.try(&.as_s?)
          {% for member in members %}
            return versions({{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, any, counts) if tag == {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_TAG
          {% end %}
        {% end %}
      {% elsif T < ::Punch::Composite %}
        object = any.as_h? || return
        key = "#{T.name} version #{object[VERSION_KEY]?.try(&.raw.as?(Int64)) || 1}"
        counts[key] = (counts[key]? || 0_i64) + 1
        {% for ivar in T.instance_vars %}
          {% unless ivar.name.stringify == "punch_unknown" %}
            object[{{ ivar.name.stringify }}]?.try { |field| versions({{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, field, counts) }
          {% end %}
        {% end %}
      {% elsif T.name(generic_args: false) == "Array" %}
        any.as_a?.try &.each { |element| versions({{ T.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, element, counts) }
      {% elsif T.name(generic_args: false) == "Hash" %}
        any.as_h?.try &.each_value { |element| versions({{ T.type_vars.last.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, element, counts) }
      {% end %}
    end

    # --- Writing -------------------------------------------------------------

    # Writes the field *key* of a stored document; a `nil` field is left out.
    def self.store(json : JSON::Builder, key : String, value) : Nil
      return if value.nil?

      json.field(key) { store_value(json, value) }
    end

    # Writes the keys a document was read with that this release does not
    # know, after the declared ones.
    def self.store_unknown(json : JSON::Builder, unknown : UnknownKeys?) : Nil
      unknown.try &.each { |key, value| json.field(key) { value.to_json(json) } }
    end

    # :nodoc:
    def self.store_value(json : JSON::Builder, value : String | Int64 | Float64 | Bool | Int32) : Nil
      value.to_json(json)
    end

    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Time) : Nil
      json.string(Stored::TIME_FORMAT.format(value.to_utc))
    end

    # A domain primitive as its stored value: a typed ID with a public
    # form keeps the rowid, like every value the app stores for itself.
    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Primitive) : Nil
      store_value(json, value.value)
    end

    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Composite) : Nil
      value.punch_store(json)
    end

    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Array) : Nil
      json.array { value.each { |element| store_value(json, element) } }
    end

    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Hash) : Nil
      json.object do
        value.each { |key, element| json.field(key.is_a?(Primitive) ? key.value.to_s : key.to_s) { store_value(json, element) } }
      end
    end

    # Inside an encrypted document, which is ciphertext as a whole.
    # :nodoc:
    def self.store_value(json : JSON::Builder, value : Secret) : Nil
      store_value(json, value.unwrap)
    end

    # Writes the field *key* of a result; a `nil` field is left out.
    def self.write(json : JSON::Builder, key : String, value) : Nil
      return if value.nil?

      json.field(key) { value.to_json(json) }
    end

    # --- Declarations ----------------------------------------------------------

    # Parses a declared default, once at program start (the generated
    # file names each default's constant at its top level), so a default
    # that does not parse fails every spec run, `punch check`, and boot,
    # at the declaration *where*.
    def self.default(type : T.class, literal : String | Int64 | Float64 | Bool | Int32, where : String) : T forall T
      value(T, JSON::Any.new(literal.is_a?(Int32) ? literal.to_i64 : literal), "$")
    rescue ex : Unreadable
      raise ArgumentError.new("#{where}: the default #{literal.inspect} does not parse as #{T}: #{ex.reason}")
    end
  end
end
