require "socket"

module Punch::HTTP
  # The proxies whose forwarded headers are believed. Behind a reverse proxy
  # the client address comes from `X-Forwarded-For`; believing it from
  # anyone else lets clients spoof their address, and ignoring it from the
  # proxy treats every client as one.
  #
  # ```
  # Punch::HTTP::TrustedProxies.parse(["10.0.0.0/8", "fd00::/8", "127.0.0.1"])
  # ```
  #
  # Checked when the server boots: an entry that does not parse, or one that
  # trusts every address, is a configuration error.
  struct TrustedProxies
    # One address range, stored as 16 bytes: IPv4 as IPv4-mapped IPv6.
    record Range, bytes : StaticArray(UInt8, 16), prefix : Int32 do
      def includes?(address : StaticArray(UInt8, 16)) : Bool
        full, rest = prefix.divmod(8)
        full.times { |i| return false unless bytes[i] == address[i] }
        return true if rest == 0

        mask = 0xFF_u8 << (8 - rest)
        (bytes[full] & mask) == (address[full] & mask)
      end
    end

    class Error < Exception
    end

    getter ranges : Array(Range)

    def initialize(@ranges : Array(Range))
    end

    # No proxy: forwarded headers are ignored and the peer is the client.
    def self.none : self
      new([] of Range)
    end

    # Raises `Error` for an entry that is malformed or trusts every address.
    # *what* names an entry in the message: the allow list of probe bans
    # (`Probes::Settings`) is read with the same rules.
    def self.parse(entries : Enumerable(String), what : String = "trusted proxy") : self
      new(entries.map { |entry| range(entry, what) })
    end

    def empty? : Bool
      ranges.empty?
    end

    def includes?(address : String) : Bool
      return false if ranges.empty?

      bytes = TrustedProxies.bytes(address) || return false
      ranges.any?(&.includes?(bytes))
    end

    private def self.range(entry : String, what : String) : Range
      address, slash, length = entry.strip.partition('/')
      bytes = self.bytes(address) || raise Error.new("#{what} #{entry.inspect} is not an IP address or range")
      v4 = !address.includes?(':')
      max = v4 ? 32 : 128
      bits = slash.empty? ? max : (length.to_i? || -1)
      raise Error.new("#{what} #{entry.inspect} has an invalid prefix length") unless 0 <= bits <= max
      # Shorter prefixes add up to everyone (`0.0.0.0/1` and
      # `128.0.0.0/1`); no proxy network is wider than `10.0.0.0/8` or
      # `fd00::/8`.
      if bits < 8
        why = what == "trusted proxy" ? "trusts every address, or nearly, which lets any client spoof its address: name the proxy's network" : "covers every address, or nearly: name a network"
        raise Error.new("#{what} #{entry.inspect} #{why}, no wider than /8")
      end
      Range.new(bytes, v4 ? bits + 96 : bits)
    end

    # The 16-byte form of an IPv4 or IPv6 address, or `nil`.
    protected def self.bytes(address : String) : StaticArray(UInt8, 16)?
      result = StaticArray(UInt8, 16).new(0_u8)
      if v4 = Socket::IPAddress.parse_v4_fields?(address)
        result[10] = result[11] = 0xFF_u8
        4.times { |i| result[12 + i] = v4[i] }
      elsif v6 = Socket::IPAddress.parse_v6_fields?(address)
        8.times do |i|
          result[2 * i] = (v6[i] >> 8).to_u8
          result[2 * i + 1] = (v6[i] & 0xFF).to_u8
        end
      else
        return
      end
      result
    end

    # Canonical text of an address: dotted IPv4 also for IPv4-mapped IPv6,
    # compressed lowercase IPv6. `nil` if *address* does not parse.
    def self.canonical(address : String) : String?
      bytes = self.bytes(address) || return
      if bytes.to_slice[0, 10].all?(&.zero?) && bytes[10] == 0xFF && bytes[11] == 0xFF
        "#{bytes[12]}.#{bytes[13]}.#{bytes[14]}.#{bytes[15]}"
      else
        Socket::IPAddress.new(address, 0).address
      end
    end
  end
end
