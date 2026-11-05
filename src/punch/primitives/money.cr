module Punch
  # An amount of money in the minor unit of its currency: cents for `EUR`
  # and `USD`, yen for `JPY` (ISO 4217). Integers only, so sums never round.
  #
  # On the wire an amount is a JSON integer (`1250` is 12.50 EUR) and the
  # currency travels once, beside it or on the parent object, as a
  # `Punch::Currency`. In the database it is an `INTEGER` column. Amounts
  # stay within ±(2^53 − 1), the integers a JavaScript client reads exactly.
  #
  # Arithmetic beyond that range raises `OverflowError`: bound the inputs
  # that feed a sum (line counts, quantities, unit prices) so it cannot.
  struct Money
    include Primitive(Int64)
    include Comparable(Money)

    MAX = (1_i64 << 53) - 1

    def self.json_schema
      {minimum: -MAX, maximum: MAX}
    end

    def self.parse(raw : Int) : self | Invalid
      raw >= -MAX && raw <= MAX ? new(raw.to_i64) : Invalid.new("out_of_range", min: -MAX, max: MAX)
    end

    def self.zero : self
      new(0_i64)
    end

    def +(other : Money) : Money
      Money.checked(value + other.value)
    end

    def -(other : Money) : Money
      Money.checked(value - other.value)
    end

    def *(other : Int) : Money
      Money.checked(value * other)
    end

    def - : Money
      Money.checked(-value)
    end

    def <=>(other : Money) : Int32
      value <=> other.value
    end

    def zero? : Bool
      value.zero?
    end

    def negative? : Bool
      value.negative?
    end

    protected def self.checked(amount : Int64) : Money
      raise OverflowError.new("Money out of range: #{amount}") unless amount >= -MAX && amount <= MAX
      new(amount)
    end
  end

  # A currency as its ISO 4217 code, such as `EUR`: three uppercase ASCII
  # letters. Checked for form, not against the list of active codes.
  struct Currency
    include Primitive(String)

    FORMAT = /\A[A-Z]{3}\z/

    # Currencies whose minor unit is not the cent (ISO 4217): `JPY` has
    # none, `KWD` thousandths. Every other code has two decimals.
    MINOR_UNITS = {
      "BIF" => 0, "CLP" => 0, "DJF" => 0, "GNF" => 0, "ISK" => 0, "JPY" => 0, "KMF" => 0,
      "KRW" => 0, "PYG" => 0, "RWF" => 0, "UGX" => 0, "UYI" => 0, "VND" => 0, "VUV" => 0,
      "XAF" => 0, "XOF" => 0, "XPF" => 0,
      "BHD" => 3, "IQD" => 3, "JOD" => 3, "KWD" => 3, "LYD" => 3, "OMR" => 3, "TND" => 3,
      "CLF" => 4, "UYW" => 4,
    }

    def self.json_schema
      {pattern: "^[A-Z]{3}$"}
    end

    def self.parse(raw : String) : self | Invalid
      FORMAT.matches?(raw) ? new(raw) : Invalid.new("invalid_currency")
    end

    # The decimals of an amount in this currency: an amount of `1250` is
    # 12.50 EUR, but 1,250 JPY.
    def minor_unit : Int32
      MINOR_UNITS[value]? || 2
    end
  end
end
