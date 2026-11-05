module Billing::Invoices
  # One line of an invoice in a request.
  struct LineInput
    include Punch::Input

    getter description : Punch::NonEmptyString
    getter quantity : Quantity
    # Price of one unit in minor units of the invoice's currency.
    getter unit_price : Punch::Money

    def check(errors : Punch::Rejection::Collector) : Nil
      max = Invoice::MAX_UNIT_PRICE
      errors.add("unit_price", Punch::Invalid.new("out_of_range", min: -max, max: max)) if unit_price.value.abs > max
    end

    def to_line : Invoice::Line
      Invoice::Line.new(description, quantity, unit_price)
    end
  end

  # Rejects more lines than an invoice may have.
  def self.check_lines(lines : Array(LineInput)?, errors : Punch::Rejection::Collector) : Nil
    if lines && lines.size > Invoice::MAX_LINES
      errors.add("lines", Punch::Invalid.new("too_many", max: Invoice::MAX_LINES))
    end
  end
end
