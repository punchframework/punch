module Punch
  # The body and headers of a Command's request as they arrived, for
  # checking a signature over the exact bytes. A Command asks for it in
  # `call` (`request : Punch::RawRequest`), and the router passes it.
  #
  # Inbound webhooks receive through it: each provider's `Receive` Command,
  # and the provider's `verifier`, `idempotency_key`, and `parse` read it,
  # also as stored and loaded again for processing. A Command that takes it
  # gets only its path parameters parsed; the body is its to read, of any
  # content type. Never record it on a trace: it holds secrets and personal
  # data.
  struct RawRequest
    # The body as received, `""` when there was none.
    getter body : String

    def initialize(@body : String, @headers : ::HTTP::Headers)
    end

    # The value of the header *name*, case-insensitive, or `nil`.
    def header(name : String) : String?
      @headers[name]?
    end

    def inspect(io : IO) : Nil
      io << "#<Punch::RawRequest " << @body.bytesize << " bytes>"
    end
  end
end
