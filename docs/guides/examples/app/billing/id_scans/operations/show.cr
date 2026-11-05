module Billing::IdScans
  @[Punch::Authorize(Own)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter id_scan_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      scan = Table.find(db, input.id_scan_id)
      scan ? Detail.of(scan) : NotFound.new
    end
  end
end
