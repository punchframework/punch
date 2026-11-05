require "random/secure"

module Punch::Trace
  # A 16-byte trace ID (W3C Trace Context). Never all zeros.
  struct TraceID
    getter bytes : StaticArray(UInt8, 16)

    def initialize(@bytes : StaticArray(UInt8, 16))
    end

    def self.parse?(hex : String) : TraceID?
      bytes = Trace.hex_bytes?(hex, 16) || return
      bytes.all?(&.zero?) ? nil : new(bytes)
    end

    def to_s(io : IO) : Nil
      @bytes.each(&.to_s(io, 16, precision: 2))
    end

    # The last 8 bytes as a number, for ratio sampling (as OpenTelemetry's
    # `TraceIdRatioBased` does): the same trace gets the same decision
    # wherever it is sampled.
    def low : UInt64
      IO::ByteFormat::BigEndian.decode(UInt64, @bytes.to_slice[8, 8])
    end
  end

  # An 8-byte span ID. Never zero.
  struct SpanID
    getter value : UInt64

    def initialize(@value : UInt64)
    end

    def self.parse?(hex : String) : SpanID?
      bytes = Trace.hex_bytes?(hex, 8) || return
      value = IO::ByteFormat::BigEndian.decode(UInt64, bytes.to_slice[0, 8])
      value.zero? ? nil : new(value)
    end

    def to_s(io : IO) : Nil
      @value.to_s(io, 16, precision: 16)
    end
  end

  # What a remote parent passes on: the IDs and its sampling decision.
  struct SpanContext
    getter trace_id : TraceID
    getter span_id : SpanID
    getter? sampled : Bool

    def initialize(@trace_id : TraceID, @span_id : SpanID, @sampled : Bool)
    end

    # Parses a `traceparent` header. Version `00` is read exactly; a later
    # version is read by its first four fields, as the specification asks.
    # Anything malformed is `nil`, and the request starts a trace of its own.
    def self.parse?(header : String) : SpanContext?
      header = header.strip
      return unless well_formed?(header)

      trace_id = TraceID.parse?(header[3, 32]) || return
      span_id = SpanID.parse?(header[36, 16]) || return
      flags = Trace.hex_bytes?(header[53, 2], 1) || return
      new(trace_id, span_id, flags[0].bit(0) == 1)
    end

    # Length, dashes, and version: `00` has exactly four fields, a later
    # version may add more after a dash, `ff` is invalid.
    private def self.well_formed?(header : String) : Bool
      return false if header.size < 55
      return false unless header[2] == '-' && header[35] == '-' && header[52] == '-'

      version = header[0, 2]
      return false if version == "ff" || !Trace.hex_bytes?(version, 1)

      version == "00" ? header.size == 55 : (header.size == 55 || header[55] == '-')
    end

    def traceparent : String
      "00-#{trace_id}-#{span_id}-#{sampled? ? "01" : "00"}"
    end
  end

  # Lowercase hex only, as W3C Trace Context requires.
  protected def self.hex_bytes?(hex : String, size : Int32) : StaticArray(UInt8, 16)?
    return unless hex.bytesize == size * 2

    bytes = StaticArray(UInt8, 16).new(0)
    size.times do |index|
      high = nibble?(hex.byte_at(index * 2)) || return
      low = nibble?(hex.byte_at(index * 2 + 1)) || return
      bytes[index] = high << 4 | low
    end
    bytes
  end

  private def self.nibble?(byte : UInt8) : UInt8?
    case byte
    when '0'.ord..'9'.ord then byte - '0'.ord
    when 'a'.ord..'f'.ord then byte - 'a'.ord + 10
    end
  end
end
