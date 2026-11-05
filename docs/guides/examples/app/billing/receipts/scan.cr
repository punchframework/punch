module Billing::Receipts
  # A scan or photo of a receipt: at most 10 MB, as a PDF, PNG, or JPEG.
  @[Punch::Upload::Rules(max_size: 10_000_000, types: ["application/pdf", "image/png", "image/jpeg"])]
  struct Scan
    include Punch::Upload::Kind
  end
end
