module Punch
  # How domain values are stored in SQLite: the one conversion that
  # generated queries call on every bound parameter and every mapped column.
  # Hand-written SQL can use it too.
  #
  # | Domain type | Stored as |
  # |---|---|
  # | `Punch::Primitive(T)`, typed IDs included | `T`, its `value` |
  # | `Time` | `TEXT`, UTC, `2026-10-08T14:03:00.123456789Z` |
  # | `Bool` | `INTEGER`, 0 or 1 |
  # | `Int64`, `Float64`, `String`, `Bytes` | themselves |
  # | `Punch::Encrypted(T)` | `BLOB`: `T`'s stored form, encrypted |
  # | `Punch::BlindIndex.of(:column)` | `BLOB`: a keyed hash of that column's plaintext |
  # | A composite (`Punch.composite`) | `TEXT`: a JSON document (docs/composites.md) |
  module Stored
    # Fixed width, so stored times sort as text in time order.
    TIME_FORMAT = Time::Format.new("%Y-%m-%dT%H:%M:%S.%9NZ")

    # SQLite's own `datetime()` form, read as UTC; written by
    # `DEFAULT (datetime('now'))`.
    SQLITE_TIME_FORMAT = Time::Format.new("%Y-%m-%d %H:%M:%S", Time::Location::UTC)

    # The stored form of *value*, for a bound parameter.
    def self.dump(value : Primitive)
      value.value
    end

    def self.dump(value : Time) : String
      TIME_FORMAT.format(value.to_utc)
    end

    def self.dump(value : Int64 | Float64 | String | Bytes | Bool?)
      value
    end

    # A composite stored as a JSON document.
    def self.dump(value : Composite) : String
      Composite.dump(value)
    end

    # Parses the stored value *raw* into *type*. A value that does not parse
    # is a bug or bad data, never coerced: it raises `Database::RowError`
    # naming *table*, *column*, and the row's ID, if the query selected it.
    # The value itself is left out of the message.
    def self.load(type : T.class, raw : R, table : String, column : String, row_id : Int64?) : T forall T, R
      {% if T == R %}
        raw
      {% elsif T < ::Punch::Composite || (T.union? && T.union_types.all? { |member| member < ::Punch::Composite }) %}
        {% raise "#{T} is a composite, stored as a JSON document in TEXT, not as #{R}" unless R == String %}
        Composite.load(T, raw, table, column, row_id)
      {% elsif T == Time %}
        {% raise "Time is stored as String (TEXT), not as #{R}" unless R == String %}
        load_time(raw, table, column, row_id)
      {% elsif T == Bool %}
        {% raise "Bool is stored as Int64 (INTEGER), not as #{R}" unless R == Int64 %}

        case raw
        when 0 then false
        when 1 then true
        else        raise Database::RowError.new(table, column, row_id, T.name, "not_boolean")
        end
      {% else %}
        {% primitive = T.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
        {% raise "#{T} is not a domain primitive, Time, Bool, or a composite, so it cannot be loaded from a column" unless primitive %}
        {% stored = primitive.type_vars.first %}
        {% raise "#{T} is stored as #{stored}, but the column holds #{R}. Map the column to a type stored as #{R}, or change the column's type." unless stored == R %}

        case parsed = T.parse(raw)
        in T       then parsed
        in Invalid then raise Database::RowError.new(table, column, row_id, T.name, parsed.code)
        end
      {% end %}
    end

    # Decrypts the ciphertext *raw* of an encrypted column with the
    # column's key, then parses the plaintext as *T* like any stored
    # value. A value that does not decrypt (another column's, a retired
    # key's, damaged) raises `Database::RowError` with `not_decrypting`.
    def self.load(type : Encrypted(T).class, raw : Bytes, table : String, column : String, row_id : Int64?) : Secret(T) forall T
      plain = encryptor(table, column).decrypt(raw) || raise Database::RowError.new(table, column, row_id, type.name, "not_decrypting")
      Secret.new(load(T, from_plaintext(Encrypted.stored_type(T), plain, table, column, row_id), table, column, row_id))
    end

    # The ciphertext of *value* for the encrypted column *table*.*column*,
    # under the key ring's signing key and a fresh nonce: equal values
    # encrypt differently every time.
    def self.encrypt(value : Secret(T), table : String, column : String) : Bytes forall T
      encryptor(table, column).encrypt(plaintext(encrypted_form(value.unwrap)))
    end

    # An encrypted document may hold what a plain one may not.
    private def self.encrypted_form(value : Composite) : String
      Composite.dump(value)
    end

    private def self.encrypted_form(value)
      dump(value)
    end

    def self.encrypt(value : Nil, table : String, column : String) : Nil
    end

    # The key ring's encryptor for an encrypted column; its key is derived
    # from the purpose `column:<table>.<column>`.
    def self.encryptor(table : String, column : String) : KeyRing::Encryptor
      KeyRing.current.encryptor("column:#{table}.#{column}")
    end

    # The blind index value of *value* for the column *table*.*column*,
    # under the key ring's signing key: what a write stores. Generated
    # code passes the encrypted column's value, `Punch::Secret(T)`, or a
    # parameter's `T`.
    def self.blind_index(value : Secret(T), table : String, column : String) : Bytes forall T
      blind_index(value.unwrap, table, column)
    end

    def self.blind_index(value : Nil, table : String, column : String) : Nil
    end

    def self.blind_index(value : Primitive | Time | Bool | Int64 | Float64 | String | Bytes, table : String, column : String) : Bytes
      index(table, column).digest(plaintext(dump(value)))
    end

    # What a lookup binds for `column = :value`, which the generator writes
    # as `column IN carray(?)`: the index values of *value* under every key
    # of the ring, so rows written before a rotation are found too.
    def self.blind_lookup(value : Primitive | Time | Bool | Int64 | Float64 | String | Bytes, table : String, column : String) : Database::Values
      blind_lookups([value], table, column)
    end

    # What `column IN carray(:values)` binds for a blind index: the index
    # values of each of *values* under every key of the ring.
    def self.blind_lookups(values : Array(T), table : String, column : String) : Database::Values forall T
      hash = index(table, column)
      Database::Values.new(values.flat_map { |value| hash.digests(plaintext(dump(value))) })
    end

    # Most elements an array parameter (`id IN carray(:ids)`) binds; a
    # generated query returns `Punch::Invalid` `too_many` for more.
    ARRAY_MAX = 10_000

    # The stored form of each of *values*, for `IN carray(?)`.
    def self.array(values : Array(T)) : Database::Values forall T
      Database::Values.new(values.map { |value| element(dump(value)) })
    end

    private def self.element(value : Int) : Int64
      value.to_i64
    end

    private def self.element(value : Bool) : Int64
      value ? 1_i64 : 0_i64
    end

    private def self.element(value : Float) : Float64
      value.to_f64
    end

    private def self.element(value : String) : String
      value
    end

    private def self.element(value : Bytes) : Bytes
      value
    end

    # The key ring's hash for a blind index column; its key is derived
    # from the purpose `blind_index:<table>.<column>`.
    def self.index(table : String, column : String) : KeyRing::BlindIndex
      KeyRing.current.blind_index("blind_index:#{table}.#{column}")
    end

    # The plaintext of a stored value: text as UTF-8, numbers as decimal
    # text, `Bool` as `0` or `1`, bytes as they are.
    # :nodoc:
    def self.plaintext(value : String) : Bytes
      value.to_slice
    end

    # :nodoc:
    def self.plaintext(value : Bytes) : Bytes
      value
    end

    # :nodoc:
    def self.plaintext(value : Int64 | Float64) : Bytes
      value.to_s.to_slice
    end

    # :nodoc:
    def self.plaintext(value : Bool) : Bytes
      (value ? "1" : "0").to_slice
    end

    private def self.from_plaintext(type : String.class, plain : Bytes, table : String, column : String, row_id : Int64?) : String
      String.new(plain).tap { |text| raise Database::RowError.new(table, column, row_id, "String", "invalid_encoding") unless text.valid_encoding? }
    end

    private def self.from_plaintext(type : Bytes.class, plain : Bytes, table : String, column : String, row_id : Int64?) : Bytes
      plain
    end

    private def self.from_plaintext(type : Int64.class, plain : Bytes, table : String, column : String, row_id : Int64?) : Int64
      String.new(plain).to_i64? || raise Database::RowError.new(table, column, row_id, "Int64", "not_integer")
    end

    private def self.from_plaintext(type : Float64.class, plain : Bytes, table : String, column : String, row_id : Int64?) : Float64
      String.new(plain).to_f64?(whitespace: false) || raise Database::RowError.new(table, column, row_id, "Float64", "not_real")
    end

    private def self.load_time(raw : String, table : String, column : String, row_id : Int64?) : Time
      if raw.size == 19 && raw[10]? == ' '
        SQLITE_TIME_FORMAT.parse(raw)
      else
        Time.parse_rfc3339(raw).to_utc
      end
    rescue Time::Format::Error | ArgumentError | Time::Location::InvalidTimezoneOffsetError
      raise Database::RowError.new(table, column, row_id, "Time", "invalid_time")
    end
  end

  # Marks a column as encrypted in `columns.cr`:
  # `address: Punch::Encrypted(Punch::NonEmptyString)` on a `BLOB` column.
  # Generated code encrypts `T`'s stored form on write and decrypts, then
  # parses, on read; records hold the value as `Punch::Secret(T)`. Never
  # instantiated.
  struct Encrypted(T)
    private def initialize
    end

    # The stored type of *type*, which its plaintext encodes.
    def self.stored_type(type : T.class) forall T
      {% if T == String || T == Bytes || T == Int64 || T == Float64 %}
        T
      {% elsif T == Time %}
        String
      {% elsif T == Bool %}
        Int64
      {% elsif T < ::Punch::Composite || (T.union? && T.union_types.all? { |member| member < ::Punch::Composite }) %}
        String
      {% else %}
        {% primitive = T.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
        {% raise "Punch::Encrypted(#{T}): #{T} is not a domain primitive, Time, Bool, a composite, or a stored type, so a column cannot hold it" unless primitive %}
        {{ primitive.type_vars.first }}
      {% end %}
    end
  end

  # Marks a blind index in `columns.cr`:
  # `email_index: Punch::BlindIndex.of(:email)` on a `BLOB` column beside
  # the encrypted column `email`. The column holds a keyed hash of the
  # encrypted column's plaintext, written by the generated `Table` and
  # compared by queries (`email_index = :email` takes the plain value), so a
  # unique index on it keeps values unique and lookups find them. Records
  # leave it out. Never instantiated.
  struct BlindIndex
    private def initialize
    end
  end

  # Declares how the columns of one table map to domain types, in
  # the entity's `columns.cr`. `punch db:generate` reads it; the compiler
  # checks that every type exists and can be stored.
  #
  # ```
  # Punch.table "customers", Billing::Customers,
  #   id: Billing::Customers::ID,
  #   email: Punch::Email,
  #   created_at: Time
  # ```
  #
  # The second argument is the module that receives the table's generated
  # `Record` and `Table`. Columns not listed keep their stored type.
  #
  # The macro's own parameters have names no column can have, so a column
  # called `name` is a column.
  macro table(__table, __module, **columns)
    {% typed = {} of Nil => Nil %}
    {% for column, type in columns %}
      {% if type.is_a?(Call) && type.name == "of" && type.receiver.stringify.gsub(/\A::/, "") == "Punch::BlindIndex" %}
        {% source = type.args.first %}
        {% source_type = columns[source.id] if type.args.size == 1 && source.is_a?(SymbolLiteral) %}
        {% source_type = source_type.receiver if source_type.is_a?(Call) && source_type.name == "from" %}
        {% grouped = columns.values.any? { |value| value.is_a?(NamedTupleLiteral) } %}
        {% unless grouped || (source_type.is_a?(Generic) && source_type.name.stringify.gsub(/\A::/, "") == "Punch::Encrypted") %}
          {% type.raise "#{__table.id}.#{column}: Punch::BlindIndex.of takes an encrypted column of #{__table.id}, such as Punch::BlindIndex.of(:email) (lib/punch/docs/queries.md)" %}
        {% end %}
      {% elsif type.is_a?(Call) && type.name == "from" && type.receiver.is_a?(Generic) %}
        {% typed[column.stringify] = type.receiver %}
      {% elsif type.is_a?(NamedTupleLiteral) %}
        {% type.raise "#{__table.id}.#{column}: a group of columns is {type: Composite, columns: \"prefix_\"} (lib/punch/docs/composites.md)" unless type[:type] && type[:columns].is_a?(StringLiteral) && type.keys.size == 2 %}
        {% typed[column.stringify] = type[:type] %}
      {% else %}
        {% typed[column.stringify] = type %}
      {% end %}
    {% end %}
    macro finished
      \{% for column, type in {{ typed }} %}
        \{% resolved = parse_type(type.stringify.gsub(::Punch::NAME_STARTS, "::")).resolve %}
        \{% resolved = resolved.union_types.reject { |member| member == Nil }.first if resolved.nilable? %}
        \{% encrypted = resolved.name(generic_args: false) == "Punch::Encrypted" %}
        \{% resolved = resolved.type_vars.first if encrypted %}
        \{% polymorphic = resolved.union? && resolved.union_types.all? { |member| member < ::Punch::Composite } %}
        \{% unless resolved == Time || resolved == Bool || polymorphic || resolved < ::Punch::Composite || (encrypted && [String, Bytes, Int64, Float64].includes?(resolved)) || resolved.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
          \{% type.raise "#{{{ __table }}.id}.#{column.id}: #{resolved} is not a domain primitive, Time, Bool#{encrypted ? ", a composite, or a stored type".id : ", or a composite".id}, so a column cannot #{encrypted ? "encrypt".id : "map to".id} it (lib/punch/docs/queries.md)" %}
        \{% end %}
      \{% end %}
    end
  end
end
