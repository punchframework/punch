require "json"

module Punch::Upload
  # Lowercase Base32 (RFC 4648 without padding), the alphabet of tickets
  # and upload IDs.
  # :nodoc:
  module Alphabet
    CHARS = "abcdefghijklmnopqrstuvwxyz234567"

    def self.random(bytes : Int32) : String
      encode(Random::Secure.random_bytes(bytes))
    end

    def self.encode(data : Bytes) : String
      String.build do |io|
        buffer = 0
        bits = 0
        data.each do |byte|
          buffer = (buffer << 8) | byte
          bits += 8
          while bits >= 5
            bits -= 5
            io << CHARS[(buffer >> bits) & 31]
          end
        end
        io << CHARS[(buffer << (5 - bits)) & 31] if bits > 0
      end
    end
  end

  # The secret that names one upload until the app claims it: handed out
  # with the grant, sent with the check and with the app's form. 160
  # random bits; `punch_uploads` keeps only its SHA-256.
  struct Ticket
    include Punch::Primitive(String)

    PREFIX  = "upl_"
    PATTERN = /\Aupl_[a-z2-7]{32}\z/

    def self.parse(raw : String) : self | Invalid
      raw.valid_encoding? && PATTERN.matches?(raw) ? new(raw) : Invalid.new("invalid_upload")
    end

    def self.json_schema
      {pattern: "^upl_[a-z2-7]{32}$"}
    end

    # :nodoc:
    def self.generate : self
      new("#{PREFIX}#{Alphabet.random(20)}")
    end

    # What `punch_uploads` keeps.
    # :nodoc:
    def digest : Bytes
      Digest::SHA256.digest(value)
    end

    # Never shown whole: it lets anyone who has it check and claim the upload.
    def inspect(io : IO) : Nil
      io << "Punch::Upload::Ticket(" << value[0, 8] << "…)"
    end
  end

  # A checked file in the storage: the kind's name and the upload's ID,
  # `expenses.receipts.scan/k3…`. It says nothing of a scan, so an app keeps
  # a whole `Punch::Upload::File`, and uses a bare key only for a kind that
  # is not scanned. Not a secret: it reaches no file without a signed URL.
  struct Key
    include Punch::Primitive(String)

    PATTERN = /\A[a-z0-9_]+(?:\.[a-z0-9_]+)*\/[a-z2-7]{26}\z/

    def self.parse(raw : String) : self | Invalid
      raw.bytesize <= 200 && raw.valid_encoding? && PATTERN.matches?(raw) ? new(raw) : Invalid.new("invalid_upload")
    end

    def self.json_schema
      {pattern: "^[a-z0-9_]+(\\.[a-z0-9_]+)*/[a-z2-7]{26}$", maxLength: 200}
    end

    # :nodoc:
    def self.of(kind : String, id : String) : self
      new("#{kind}/#{id}")
    end

    # The kind's name.
    def kind : String
      value.partition('/')[0]
    end

    # The upload's ID.
    def id : String
      value.partition('/')[2]
    end
  end

  # Where the client sends the file, as `Punch::Upload.grant` hands it out:
  # a `PUT` of exactly `size` bytes to `url` with `headers`, before
  # `expires_at`, then `POST check` with the ticket. Answered 201.
  @[Punch::Status(201)]
  struct Grant
    include JSON::Serializable

    getter ticket : Ticket
    getter method : String = "PUT"
    getter url : String
    # Send each with exactly this value: the storage checks them. A browser
    # sets `Content-Length` itself, from the file.
    getter headers : Hash(String, String)
    getter expires_at : Time
    # Where to send the ticket once the file is uploaded.
    getter check : String = CHECK_PATH

    def initialize(@ticket : Ticket, @url : String, @headers : Hash(String, String), @expires_at : Time)
    end
  end
end
