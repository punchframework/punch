require "base64"
require "json"

module Punch
  class Database
    # Which way a query with `-- order` lines reads its order: `Asc` as
    # written, `Desc` backwards, every term reversed. Orders are written
    # ascending in their first term, so the names say what they mean. Parses
    # from a query string as `asc` or `desc`.
    enum Direction
      Asc
      Desc
    end
  end

  # One page of a `:page` query: its rows, and the cursor that continues
  # after them, `nil` on the last page. The generated method reads one row
  # more than asked for, so the last page is known without an extra query,
  # and an empty page never follows a full one.
  #
  # ```
  # page = Queries.page(db, owner_id: id, after: input.after, limit: 50)
  # page.rows       # => Array(Queries::Page::Row), at most 50
  # page.next_after # => Queries::Page::Cursor?, for the link to the next page
  # ```
  struct Paged(T, C)
    include Enumerable(T)

    getter rows : Array(T)
    # Pass as `after:` for the next page; `nil` on the last one.
    getter next_after : C?

    # *rows* as read with `fetch(limit)`; *cursor* makes the cursor after
    # the last row kept.
    def initialize(rows : Array(T), limit : Int32 | PageSize, & : T -> C)
      limit = limit.to_i
      @next_after = nil
      if rows.size > limit
        rows = rows.first(limit)
        @next_after = yield rows.last
      end
      @rows = rows
    end

    def each(& : T ->) : Nil
      @rows.each { |row| yield row }
    end

    def last_page? : Bool
      @next_after.nil?
    end

    # The `LIMIT` that reads a page of *limit* rows: one more, which tells
    # whether another page follows. A page holds at least one row.
    def self.fetch(limit : PageSize) : Int64
      limit.to_i.to_i64 + 1
    end

    def self.fetch(limit : Int32) : Int64
      raise ArgumentError.new("a page holds at least one row, not #{limit}") if limit < 1
      limit.to_i64 + 1
    end
  end

  # The token of a generated `Paged::Cursor`: the last row's sort values,
  # and for a query with `-- order` lines the order's name, `-` first when
  # read backwards (`"-name"`), as a JSON array in base64url. Not signed: a
  # cursor only says where a page starts, and the query's own conditions
  # still decide which rows anyone sees. It shows the sort values of a row
  # the client was already shown.
  #
  # Except when a sort value is a public ID (`Punch::TypedID.public_id`):
  # its rowid would count records, so the cursor is sealed, AES-256-GCM
  # under a key derived from the public-ID key, and a token that was not
  # sealed so does not decode.
  module Paged::Cursor
    # What a sort value is stored as.
    enum Kind
      Integer
      Real
      Text
    end

    # Longer tokens are refused before decoding.
    MAX = 1024

    # Whether a cursor over sort values of *types* is sealed: when one of
    # them is a typed ID with a public form.
    def self.sealed?(*types) : Bool
      types.any? { |type| type.responds_to?(:public_prefix) && !type.public_prefix.nil? }
    end

    def self.encode(key : String?, values : Array(Database::Value), direction : Database::Direction = Database::Direction::Asc, *, sealed : Bool = false) : String
      json = JSON.build do |builder|
        builder.array do
          builder.string(direction.desc? ? "-#{key}" : key) if key
          values.each do |value|
            case value
            when Bool then builder.number(value ? 1 : 0)
            when Bytes, Database::Values, Nil
              raise ArgumentError.new("a cursor holds no #{value.class}; the generator refuses such sort columns")
            else value.to_json(builder)
            end
          end
        end
      end
      return Base64.urlsafe_encode(json, padding: false) unless sealed

      box = Crypto::AESGCM.seal(Crypto::PublicIDs.cursor_key, json.to_slice)
      Base64.urlsafe_encode(box.nonce + box.tag + box.ciphertext, padding: false)
    end

    # The order's key (`""` when *layouts* has only that one), its
    # direction, and the values, each of the kind *layouts* gives for that
    # order; `nil` for anything else.
    def self.decode(raw : String, layouts : Hash(String, Array(Kind)), *, sealed : Bool = false) : {String, Database::Direction, Array(Database::Value)}?
      return if raw.empty? || raw.size > MAX || !raw.matches?(/\A[A-Za-z0-9_-]+\z/)

      items = text(raw, sealed).try { |json| JSON.parse(json).as_a? }
      return unless items

      key = ""
      direction = Database::Direction::Asc
      unless layouts.has_key?("")
        key = items.shift?.try(&.as_s?) || return
        if key.starts_with?('-')
          key = key.lchop
          direction = Database::Direction::Desc
        end
      end
      kinds = layouts[key]? || return
      return unless items.size == kinds.size

      values = [] of Database::Value
      items.zip(kinds) { |item, kind| values << (value(item, kind) || return) }
      {key, direction, values}
    rescue JSON::ParseException | Base64::Error | ArgumentError
      nil
    end

    private def self.text(raw : String, sealed : Bool) : String?
      sealed ? unseal(Base64.decode(raw)) : Base64.decode_string(raw)
    end

    private def self.unseal(bytes : Bytes) : String?
      header = Crypto::AESGCM::NONCE_SIZE + Crypto::AESGCM::TAG_SIZE
      return unless bytes.size > header

      nonce, tag = bytes[0, Crypto::AESGCM::NONCE_SIZE], bytes[Crypto::AESGCM::NONCE_SIZE, Crypto::AESGCM::TAG_SIZE]
      Crypto::AESGCM.open(Crypto::PublicIDs.cursor_key, nonce, bytes[header..], tag).try { |plain| String.new(plain) }
    end

    private def self.value(item : JSON::Any, kind : Kind) : Database::Value?
      case kind
      in .integer? then item.as_i64?
      in .real?    then item.as_f? || item.as_i64?.try(&.to_f64)
      in .text?    then item.as_s?
      end
    end

    # The JSON Schema keywords of every cursor type.
    def self.json_schema
      {minLength: 1, maxLength: MAX, pattern: "^[A-Za-z0-9_-]+$"}
    end

    # The rejection of a token that is not a cursor of this query.
    def self.invalid : Invalid
      Invalid.new("invalid_cursor")
    end
  end
end
