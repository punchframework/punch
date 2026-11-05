class Fiber
  # Whether this fiber is writing or reading stored JSON
  # (`Punch::Stored.json`). Nilable, so no constructor sets it.
  # :nodoc:
  property __punch_stored_json : Bool?
end

module Punch::Stored
  # JSON the app writes for itself, such as job payloads, step cursors and
  # cached values, as opposed to JSON it hands out. The one difference is
  # typed IDs with a public form (`Punch::TypedID.public_id`): stored JSON
  # keeps their rowid, so a payload neither depends on the public-ID key
  # nor changes when a type gains a public form, and a binary from before
  # the change still reads it during a deploy.
  #
  # ```
  # text = Punch::Stored.json(job) # {"invoice_id":42}
  # Punch::Stored.from_json(Invoices::Mail, text)
  # job.to_json # {"invoice_id":"inv_gLW26G63FZp"}
  # ```
  #
  # Both run without yielding the fiber, which carries the mode: another
  # fiber's JSON is never affected.
  def self.json(value) : String
    storing { value.to_json }
  end

  def self.from_json(type : T.class, text : String) : T forall T
    storing { T.from_json(text) }
  end

  # Whether the current fiber is inside `json` or `from_json`.
  def self.storing? : Bool
    Fiber.current.__punch_stored_json == true
  end

  private def self.storing(&)
    fiber = Fiber.current
    outer = fiber.__punch_stored_json
    fiber.__punch_stored_json = true
    begin
      yield
    ensure
      fiber.__punch_stored_json = outer
    end
  end
end
