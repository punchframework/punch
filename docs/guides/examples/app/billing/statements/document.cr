module Billing::Statements
  # A statement as the bank issued it: at most 20 MB, as a PDF.
  @[Punch::Upload::Rules(max_size: 20_000_000, types: ["application/pdf"])]
  struct Document
    include Punch::Upload::Kind
  end
end
