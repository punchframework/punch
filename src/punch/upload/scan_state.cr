module Punch::Upload
  # What a scan said of a file, for a kind with `scan: true` in its rules.
  # Punch does not scan: the app's job reads the file and records the result
  # (`File#scanned`). A file of a kind without `scan: true` has none.
  struct ScanState
    include Punch::Primitive(String)

    def self.json_schema
      {enum: ["pending", "clean", "quarantined"]}
    end

    def self.parse(raw : String) : self | Invalid
      raw.in?("pending", "clean", "quarantined") ? new(raw) : Invalid.new("invalid_choice")
    end

    # Not scanned yet.
    PENDING = new("pending")
    # Scanned, and nothing was found.
    CLEAN = new("clean")
    # Scanned, and something was found. Punch links to it no more, but a URL
    # signed before stays good until it expires, and the object stays until
    # `Punch::Upload.purge`.
    QUARANTINED = new("quarantined")

    def clean? : Bool
      value == "clean"
    end

    def pending? : Bool
      value == "pending"
    end

    def quarantined? : Bool
      value == "quarantined"
    end
  end
end
