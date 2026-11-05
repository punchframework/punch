module Ledger
  # A place on the globe; refuses what is not one.
  struct Geo
    def self.check(value : self) : Punch::Invalid?
      Punch::Invalid.new("out_of_range") unless -90 <= value.lat <= 90 && -180 <= value.lng <= 180
    end
  end
end
