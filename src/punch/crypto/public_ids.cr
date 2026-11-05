module Punch::Crypto
  # The public form of a typed ID (`Punch::TypedID.public_id`): the rowid
  # through a keyed permutation of 64 bits, written as 11 characters of
  # base58 after the type's prefix, `inv_5ZrkH8pTq2W`. Nothing is stored;
  # the same rowid always gives the same text, and every text decodes to
  # one rowid or to nothing, without a lookup.
  #
  # The permutation is a Feistel network of 8 rounds over two halves of 32
  # bits. Each round's function is SipHash-2-4 under a key per prefix,
  # derived from the app's public-ID key, so an invoice and a customer with
  # the same rowid get unrelated texts. Without the key, neighbouring rowids
  # give unrelated texts, so the public form neither counts records nor
  # lets anyone guess the next one. Anyone with the key reads the rowid:
  # a public ID hides counts, it does not grant or deny access.
  module PublicIDs
    ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    LENGTH   = 11
    ROUNDS   =  8
    PATTERN  = "[1-9A-HJ-NP-Za-km-z]{#{LENGTH}}"
    INFO     = "punch public id v2 feistel-siphash-2-4"

    @@root : Bytes?
    @@keys = {} of String => {UInt64, UInt64}
    @@cursor_key : Bytes?
    @@lock = Mutex.new

    # The key every prefix's key is derived from, `public_id_key` in the
    # app's credentials. Changing it changes every public ID.
    def self.root=(key : Bytes) : Bytes
      raise ArgumentError.new("A public-ID key has #{KEY_SIZE} bytes, not #{key.size}") unless key.size == KEY_SIZE

      @@lock.synchronize do
        @@keys.clear
        @@cursor_key = nil
        @@root = key
      end
    end

    # The AES-256-GCM key of page cursors over public IDs
    # (`Punch::Paged::Cursor`).
    def self.cursor_key : Bytes
      @@lock.synchronize do
        @@cursor_key ||= HKDF.derive(root!, "aes-256-gcm:v1:punch page cursor")
      end
    end

    def self.root? : Bytes?
      @@root
    end

    def self.encode(prefix : String, rowid : Int64) : String
      block = permute(key(prefix), rowid.to_u64!, forward: true)
      String.build(prefix.bytesize + 1 + LENGTH) do |io|
        io << prefix << '_'
        divisor = 58_u64 ** (LENGTH - 1)
        LENGTH.times do
          io << ALPHABET[(block // divisor).to_i]
          block %= divisor
          divisor //= 58
        end
      end
    end

    # The rowid in *text*, or `nil` for text of another prefix, of the
    # wrong form, or outside the rowids SQLite assigns (1 to `Int64::MAX`).
    def self.decode(prefix : String, text : String) : Int64?
      return unless text.bytesize == prefix.bytesize + 1 + LENGTH && text.starts_with?(prefix) && text.byte_at(prefix.bytesize) == '_'.ord

      block = 0_u128
      (prefix.bytesize + 1).upto(text.bytesize - 1) do |index|
        digit = DIGITS[text.byte_at(index)]
        return if digit < 0

        block = block * 58 + digit
      end
      return if block > UInt64::MAX

      rowid = permute(key(prefix), block.to_u64, forward: false)
      rowid.to_i64! if rowid >= 1 && rowid <= Int64::MAX.to_u64
    end

    # The value of each byte as a base58 digit, or -1.
    DIGITS = begin
      table = StaticArray(Int8, 256).new(-1_i8)
      ALPHABET.each_char_with_index { |char, index| table[char.ord] = index.to_i8 }
      table
    end

    private def self.key(prefix : String) : {UInt64, UInt64}
      @@lock.synchronize do
        @@keys[prefix] ||= begin
          bytes = HKDF.derive(root!, "#{INFO} #{prefix}", 16)
          {IO::ByteFormat::LittleEndian.decode(UInt64, bytes[0, 8]), IO::ByteFormat::LittleEndian.decode(UInt64, bytes[8, 8])}
        end
      end
    end

    private def self.root! : Bytes
      @@root || raise Credentials::NotLoaded.new("No public-ID key has been loaded. Declare `getter public_id_key : Punch::PublicIDKey` in the app's credentials; specs call Punch::Spec.credentials.")
    end

    private def self.permute(key : {UInt64, UInt64}, block : UInt64, forward : Bool) : UInt64
      left = (block >> 32).to_u32!
      right = block.to_u32!
      if forward
        ROUNDS.times do |round|
          left, right = right, left ^ round(key, round, right)
        end
      else
        (ROUNDS - 1).downto(0) do |round|
          left, right = right ^ round(key, round, left), left
        end
      end
      (left.to_u64 << 32) | right.to_u64
    end

    private def self.round(key : {UInt64, UInt64}, round : Int32, half : UInt32) : UInt32
      SipHash.word(key[0], key[1], (round.to_u64 << 32) | half).to_u32!
    end
  end
end
