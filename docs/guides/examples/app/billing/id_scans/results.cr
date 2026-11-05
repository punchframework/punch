module Billing::IdScans
  # An ID scan as the API shows it: `url` only once the scan passed it.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    state : Punch::Upload::ScanState?,
    url : String? do
    include JSON::Serializable

    def self.of(scan : Record) : self
      new(scan.id, scan.photo.scan_state, Punch::Upload.url?(scan.photo, download: true))
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end
end
