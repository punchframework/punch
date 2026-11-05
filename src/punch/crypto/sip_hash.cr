module Punch::Crypto
  # SipHash-2-4 (Aumasson and Bernstein, 2012): a keyed function built for
  # short inputs, in pure Crystal and without allocating. Punch uses it as
  # the round function of public IDs (`Crypto::PublicIDs`), where it runs
  # eight times per ID. Checked against the paper's test vectors.
  module SipHash
    # The 64-bit SipHash-2-4 of *message* under the key *k0*, *k1* (the
    # 16 key bytes read as two little-endian words).
    def self.digest(k0 : UInt64, k1 : UInt64, message : Bytes) : UInt64
      v0, v1, v2, v3 = start(k0, k1)
      blocks = message.size // 8
      blocks.times do |index|
        word = IO::ByteFormat::LittleEndian.decode(UInt64, message[index * 8, 8])
        v0, v1, v2, v3 = compress(v0, v1, v2, v3, word)
      end
      last = message.size.to_u64! << 56
      (message.size - blocks * 8).times do |index|
        last |= message[blocks * 8 + index].to_u64 << (8 * index)
      end
      v0, v1, v2, v3 = compress(v0, v1, v2, v3, last)
      finish(v0, v1, v2, v3)
    end

    # The digest of the 8 bytes of *word* in little-endian order, the
    # same as `digest(k0, k1, bytes)`.
    def self.word(k0 : UInt64, k1 : UInt64, word : UInt64) : UInt64
      v0, v1, v2, v3 = start(k0, k1)
      v0, v1, v2, v3 = compress(v0, v1, v2, v3, word)
      v0, v1, v2, v3 = compress(v0, v1, v2, v3, 8_u64 << 56)
      finish(v0, v1, v2, v3)
    end

    private def self.start(k0 : UInt64, k1 : UInt64) : {UInt64, UInt64, UInt64, UInt64}
      {k0 ^ 0x736f6d6570736575_u64, k1 ^ 0x646f72616e646f6d_u64, k0 ^ 0x6c7967656e657261_u64, k1 ^ 0x7465646279746573_u64}
    end

    private def self.compress(v0 : UInt64, v1 : UInt64, v2 : UInt64, v3 : UInt64, word : UInt64) : {UInt64, UInt64, UInt64, UInt64}
      v3 ^= word
      v0, v1, v2, v3 = round(v0, v1, v2, v3)
      v0, v1, v2, v3 = round(v0, v1, v2, v3)
      {v0 ^ word, v1, v2, v3}
    end

    private def self.finish(v0 : UInt64, v1 : UInt64, v2 : UInt64, v3 : UInt64) : UInt64
      v2 ^= 0xff_u64
      4.times { v0, v1, v2, v3 = round(v0, v1, v2, v3) }
      v0 ^ v1 ^ v2 ^ v3
    end

    private def self.round(v0 : UInt64, v1 : UInt64, v2 : UInt64, v3 : UInt64) : {UInt64, UInt64, UInt64, UInt64}
      v0 &+= v1
      v1 = v1.rotate_left(13) ^ v0
      v0 = v0.rotate_left(32)
      v2 &+= v3
      v3 = v3.rotate_left(16) ^ v2
      v0 &+= v3
      v3 = v3.rotate_left(21) ^ v0
      v2 &+= v1
      v1 = v1.rotate_left(17) ^ v2
      v2 = v2.rotate_left(32)
      {v0, v1, v2, v3}
    end
  end
end
