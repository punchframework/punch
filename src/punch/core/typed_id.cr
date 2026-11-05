module Punch
  # The ID of one kind of record, so that a customer ID cannot be passed where
  # an invoice ID is expected. Backed by a positive `Int64`, the SQLite rowid.
  #
  # ```
  # module Billing::Invoices
  #   struct ID < Punch::TypedID
  #   end
  # end
  #
  # Billing::Invoices::ID.parse("42") # => Billing::Invoices::ID or Punch::Invalid
  # ```
  #
  # With `public_id "inv"`, the ID shows a public form outside the app
  # (paths, query strings, JSON, DOM IDs): `inv_5ZrkH8pTq2W`, which neither
  # counts records nor can be guessed (`Crypto::PublicIDs`). Inside, in
  # queries, it stays the rowid.
  abstract struct TypedID
    include Primitive(Int64)

    # Per subtype, so that IDs of different types do not compare.
    macro inherited
      include Comparable(self)
    end

    # Gives this ID type a public form with *prefix*: lowercase letters,
    # unique among the app's ID types.
    macro public_id(prefix)
      {% raise "public_id takes a prefix of 2 to 8 lowercase letters, such as \"inv\"" unless prefix.is_a?(StringLiteral) && prefix =~ /\A[a-z]{2,8}\z/ %}
      PUBLIC_PREFIX = {{ prefix }}

      # One type per prefix, so that a public ID names its type.
      macro finished
        \{% others = ::Punch::TypedID.all_subclasses.select { |type| type != @type && type.has_constant?("PUBLIC_PREFIX") && type.constant("PUBLIC_PREFIX") == {{ prefix }} } %}
        \{% raise "public_id #{{{ prefix }}}: #{@type} and #{others.first} have the same prefix; give each ID type its own" unless others.empty? %}
      end

      def self.public_prefix : String?
        PUBLIC_PREFIX
      end

      # What `parse` accepts, for the JSON Schema of answers and inputs.
      # Stored payloads keep the rowid and its schema (`Punch::Stored.json`).
      def self.public_pattern : String
        "^#{PUBLIC_PREFIX}_#{::Punch::Crypto::PublicIDs::PATTERN}$"
      end

      # Only the public form, as `to_s` writes it: the rowid's decimal form
      # would count records.
      def self.parse(raw : String) : self | ::Punch::Invalid
        (rowid = ::Punch::Crypto::PublicIDs.decode(PUBLIC_PREFIX, raw)) ? new(rowid) : ::Punch::Invalid.new("invalid_id")
      end

      def to_s(io : IO) : Nil
        io << ::Punch::Crypto::PublicIDs.encode(PUBLIC_PREFIX, value)
      end

      # The public form, except in what the app stores for itself (job
      # payloads, step cursors, cached values), which keeps the rowid:
      # `Punch::Stored.json`.
      def to_json(json : ::JSON::Builder) : Nil
        ::Punch::Stored.storing? ? json.number(value) : json.string(to_s)
      end

      # The public form only, except in stored JSON (`Punch::Stored.from_json`),
      # which holds the rowid. A number from outside would count records.
      def self.new(pull : ::JSON::PullParser) : self
        line, column = pull.location
        parsed = if ::Punch::Stored.storing?
                   pull.kind.int? ? parse(pull.read_int) : ::Punch::Invalid.new("expected_integer")
                 else
                   pull.kind.string? ? parse(pull.read_string) : ::Punch::Invalid.new("expected_string")
                 end
        raise ::JSON::ParseException.new("#{self}: #{parsed.code}", line, column) if parsed.is_a?(::Punch::Invalid)
        parsed
      end
    end

    def self.public_prefix : String?
      nil
    end

    # Written by `punch db:generate` for a table whose rowid is not
    # `AUTOINCREMENT`. SQLite then gives the rowid of a deleted last row to
    # the next row, so a public ID of *type* in an old link would name a
    # new record: that does not compile.
    macro reusing_rowids(type, table)
      macro finished
        \{% if {{ type }}.resolve.has_constant?("PUBLIC_PREFIX") %}
          \{% raise "#{{{ type.stringify }}.id} has a public form, so the table #{{{ table }}.id} needs `INTEGER PRIMARY KEY AUTOINCREMENT`: without it, a deleted row's public ID names the next row inserted. Rebuild the table in a migration (lib/punch/docs/migrations.md)." %}
        \{% end %}
      end
    end

    # The prefixes of every ID type with a public form, sorted.
    def self.public_prefixes : Array(String)
      {% begin %}
        [{% for type in @type.all_subclasses %}{% if type.has_constant?("PUBLIC_PREFIX") %}{{ type.constant("PUBLIC_PREFIX") }}, {% end %}{% end %}] of String
      {% end %}.sort
    end

    def self.json_schema
      {minimum: 1}
    end

    def self.parse(raw : Int) : self | Invalid
      raw > 0 && raw <= Int64::MAX ? new(raw.to_i64) : Invalid.new("invalid_id")
    end

    # Accepts the decimal form used in paths and query strings: digits only,
    # no sign, no leading zeros, no surrounding whitespace. A type with
    # `public_id` accepts its public form instead; either way, `parse` reads
    # what `to_s` writes.
    def self.parse(raw : String) : self | Invalid
      return Invalid.new("invalid_id") unless raw.valid_encoding? && raw.matches?(/\A[1-9][0-9]{0,18}\z/)

      (id = raw.to_i64?) ? new(id) : Invalid.new("invalid_id")
    end

    def <=>(other : self) : Int32
      value <=> other.value
    end
  end
end
