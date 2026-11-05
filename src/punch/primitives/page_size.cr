module Punch
  # How many rows a page holds, 1 to 100: the `limit` of a list. An input
  # takes it as a field, so the bounds are written once and reach OpenAPI
  # (`minimum`, `maximum`), forms, and the rejection (`out_of_range`, with
  # `min` and `max`); a `:page` method takes it as `limit:`, an `Int32` too.
  #
  # ```
  # struct Input
  #   include Punch::Input
  #   getter limit : Punch::PageSize = Punch::PageSize.of(50)
  # end
  # # Queries.page(db, after: input.after, limit: input.limit)
  # ```
  struct PageSize
    include Primitive(Int32)

    MIN =   1
    MAX = 100

    def self.json_schema
      {minimum: MIN, maximum: MAX}
    end

    def self.parse(raw : Int32) : self | Invalid
      raw.in?(MIN..MAX) ? new(raw) : Invalid.new("out_of_range", min: MIN, max: MAX)
    end

    # A size written in code, such as an input's default. Raises
    # `ArgumentError` outside the bounds, at the first use.
    def self.of(size : Int32) : self
      case parsed = parse(size)
      in PageSize then parsed
      in Invalid  then raise ArgumentError.new("a page size is #{MIN} to #{MAX}, not #{size}")
      end
    end

    def to_i : Int32
      value
    end
  end
end
