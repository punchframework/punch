module Billing::Receipts
  # A receipt as the API shows it. `scan_url` fetches the scan from the
  # storage for the next hour; a client asks again for a new one.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    description : Punch::NonEmptyString,
    scan_name : Punch::Upload::Filename,
    scan_type : String,
    scan_size : Int64,
    scan_url : String? do
    include JSON::Serializable

    def self.of(receipt : Record) : self
      scan = receipt.scan
      new(receipt.id, receipt.description, scan.filename, scan.content_type, scan.size, Punch::Upload.url?(scan))
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end
end
