require "../../src/punch"

module Invoices
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Archive < Punch::Command
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter invoice_id : Int64
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

@[Punch::Route("POST", "/invoices/:id/archive")]
@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct ArchiveAlias < Punch::Command
  struct Input
    include Punch::Input
    @[Punch::PathParam]
    getter id : Int64
  end

  def call(input : Input, db : Punch::Writer) : Nil
  end
end

Punch::Routing.routes
