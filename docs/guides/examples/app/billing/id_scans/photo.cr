module Billing::IdScans
  # A photo of an identity document: at most 8 MB, as a JPEG or PNG. The app
  # scans these, so a claimed one starts `pending`.
  @[Punch::Upload::Rules(max_size: 8_000_000, types: ["image/jpeg", "image/png"], scan: true)]
  struct Photo
    include Punch::Upload::Kind
  end
end
