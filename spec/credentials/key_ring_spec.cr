require "../spec_helper"

module KeyRingSpec
  def self.key(id : Int32, pending = false) : Punch::KeyRing::Key
    Punch::KeyRing::Key.new(id.to_u32, Bytes.new(32) { |index| (index * 7 + id).to_u8 }, Time.utc(2026, 10, 9), pending)
  end

  def self.ring(*keys : Punch::KeyRing::Key) : Punch::KeyRing
    Punch::KeyRing.new(keys.to_a)
  end

  struct App
    include Punch::Credentials

    getter secret_key_base : Punch::KeyRing
  end
end

describe Punch::KeyRing do
  it "parses the text form: the first key that is not pending signs" do
    a, b = KeyRingSpec.key(2, pending: true), KeyRingSpec.key(1)
    ring = Punch::KeyRing.parse("#{a.to_text}\n#{b.to_text}").as(Punch::KeyRing)
    ring.keys.map(&.id).should eq([2, 1])
    ring.signing.id.should eq(1)
    ring.keys.first.pending?.should be_true
    ring.keys.first.created.should eq(Time.utc(2026, 10, 9))
    Punch::KeyRing.parse("#{a.to_text}, #{b.to_text}").as(Punch::KeyRing).to_text.should eq(ring.to_text)
  end

  it "rejects malformed rings by position, never showing key material" do
    good = KeyRingSpec.key(1).to_text
    {
      ""                                   => {"reason" => "empty"},
      "#{good}\n1:2026-10-09:abc"          => {"reason" => "malformed", "entry" => 2_i64},
      "#{good}\n#{good}"                   => {"reason" => "key_ids_must_be_unique"},
      "#{good}\n#{good.sub("1:", "2:")}"   => {"reason" => "two_keys_have_the_same_secret"},
      KeyRingSpec.key(1, true).to_text     => {"reason" => "a_key_ring_needs_a_key_that_is_not_pending"},
      good.sub("1:", "0:")                 => {"reason" => "key_ids_start_at_1"},
      good.sub("1:", "4294967296:")        => {"reason" => "id", "entry" => 1_i64},
      good.sub("2026-10-09", "2026-13-40") => {"reason" => "date", "entry" => 1_i64},
    }.each do |text, params|
      invalid = Punch::KeyRing.parse(text).as(Punch::Invalid)
      invalid.code.should eq("invalid_key_ring")
      invalid.params.should eq(params.transform_values(&.as(Punch::Invalid::Param)))
    end
  end

  it "never prints a secret" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(1))
    secret = ring.to_text.split(':')[2]
    "#{ring} #{ring.inspect} #{ring.keys.first.inspect}".should_not contain(secret)
  end
end

describe Punch::KeyRing::Signer do
  it "round-trips, with the payload readable and the tag over everything" do
    signer = KeyRingSpec.ring(KeyRingSpec.key(1)).signer("invoice_link")
    message = signer.sign("42".to_slice)
    signer.verify(message).should eq("42".to_slice)
    message.size.times do |index|
      message[index] ^= 1
      signer.verify(message).should be_nil
      message[index] ^= 1
    end
    (0...message.size).each { |size| signer.verify(message[0, size]).should be_nil }
  end

  it "does not verify a message signed for another purpose" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(1))
    ring.signer("unsubscribe").verify(ring.signer("invoice_link").sign("42".to_slice)).should be_nil
    expect_raises(ArgumentError) { ring.signer("Invoice Link") }
  end

  it "expires" do
    signer = KeyRingSpec.ring(KeyRingSpec.key(1)).signer("invoice_link")
    expires = Time.utc(2026, 11, 1)
    text = signer.sign_text("42", expires_at: expires)
    signer.verify_text(text, now: expires - 1.second).should eq("42")
    signer.verify_text(text, now: expires).should be_nil
  end

  it "verifies one spelling of a signed text only" do
    signer = KeyRingSpec.ring(KeyRingSpec.key(1)).signer("invoice_link")
    # 45 + 2 bytes: the last character carries four unused bits.
    text = signer.sign_text("42")
    signer.verify_text(text).should eq("42")
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    spellings = alphabet.chars.map { |char| text[0...-1] + char }
    spellings.count { |spelling| signer.verify_text(spelling) }.should eq(1)
  end

  it "rejects text that is not URL-safe Base64 of a message" do
    signer = KeyRingSpec.ring(KeyRingSpec.key(1)).signer("invoice_link")
    text = signer.sign_text("42")
    text.should match(/\A[A-Za-z0-9_-]+\z/)
    signer.verify_text(text + "=").should be_nil
    signer.verify_text("not a token").should be_nil
    signer.verify_text("").should be_nil
  end

  it "rotates from rotate to retire: pending accepted, promoted signs, old counted, retired rejected" do
    old, fresh = KeyRingSpec.key(1), KeyRingSpec.key(2)
    before = KeyRingSpec.ring(old).signer("invoice_link")
    old_message = before.sign("a".to_slice)

    # Step 1: the new key is deployed as pending. Old processes do not know
    # it; new ones accept it but still sign with the old key.
    pending = KeyRingSpec.ring(fresh.with_pending(true), old)
    pending.signer("invoice_link").sign("b".to_slice)[1, 4].should eq(Bytes[0, 0, 0, 1])
    pending.signer("invoice_link").verify(old_message).should_not be_nil

    # Step 2: promoted. What it signs is accepted by the pending ring, so
    # a process still on step 1 verifies it during the handover.
    promoted_ring = KeyRingSpec.ring(fresh, old)
    promoted = promoted_ring.signer("invoice_link")
    new_message = promoted.sign("c".to_slice)
    new_message[1, 4].should eq(Bytes[0, 0, 0, 2])
    pending.signer("invoice_link").verify(new_message).should_not be_nil
    promoted.verify(old_message).should_not be_nil
    promoted.verify(old_message).should_not be_nil
    promoted.verify(new_message).should_not be_nil
    promoted_ring.uses.should eq({2_u32 => 0_i64, 1_u32 => 2_i64})

    # Step 3: retired. Old messages no longer verify; new ones do.
    retired = KeyRingSpec.ring(fresh).signer("invoice_link")
    retired.verify(old_message).should be_nil
    retired.verify(new_message).should_not be_nil
  end

  it "names an old key on the request's wide event" do
    old_message = KeyRingSpec.ring(KeyRingSpec.key(1)).signer("p").sign("a".to_slice)
    ring = KeyRingSpec.ring(KeyRingSpec.key(2), KeyRingSpec.key(1))
    trace = Punch::Spec.trace { ring.signer("p").verify(old_message) }
    trace.root["punch.key_ring.old_key_id"].should eq(1)
  end
end

describe Punch::KeyRing::Encryptor do
  it "round-trips and rejects every changed byte, truncation, and another purpose" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(1))
    encryptor = ring.encryptor("column:customers.email")
    message = encryptor.encrypt("ada@example.org".to_slice)
    message.size.should eq(15 + Punch::KeyRing::Encryptor::OVERHEAD)
    encryptor.decrypt(message).should eq("ada@example.org".to_slice)
    message.size.times do |index|
      message[index] ^= 1
      encryptor.decrypt(message).should be_nil
      message[index] ^= 1
    end
    (0...message.size).each { |size| encryptor.decrypt(message[0, size]).should be_nil }
    ring.encryptor("column:customers.name").decrypt(message).should be_nil
  end

  it "decrypts under an old key, counts it, and encrypts under the signing key" do
    old_message = KeyRingSpec.ring(KeyRingSpec.key(1)).encryptor("c").encrypt("x".to_slice)
    ring = KeyRingSpec.ring(KeyRingSpec.key(2), KeyRingSpec.key(1))
    ring.encryptor("c").decrypt(old_message).should eq("x".to_slice)
    ring.encryptor("c").encrypt("x".to_slice)[1, 4].should eq(Bytes[0, 0, 0, 2])
    ring.uses[1].should eq(1)
  end

  it "is safe from many fibers on several threads" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(2), KeyRingSpec.key(1))
    old = KeyRingSpec.ring(KeyRingSpec.key(1)).encryptor("c").encrypt("old".to_slice)
    encryptor, signer = ring.encryptor("c"), ring.signer("s")
    failures = Atomic(Int32).new(0)
    done = Channel(Nil).new
    32.times do |fiber|
      spawn do
        200.times do |round|
          text = "#{fiber}-#{round}"
          failures.add(1) unless encryptor.decrypt(encryptor.encrypt(text.to_slice)) == text.to_slice
          failures.add(1) unless signer.verify_text(signer.sign_text(text)) == text
          failures.add(1) unless encryptor.decrypt(old) == "old".to_slice
        end
        done.send(nil)
      end
    end
    32.times { done.receive }
    failures.get.should eq(0)
    ring.uses[1].should eq(32 * 200)
  end
end

describe Punch::KeyRing::BlindIndex do
  it "hashes a value the same every time, keyed per purpose and root key, with the key ID in front" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(1))
    index = ring.blind_index("blind_index:customers.email_index")
    value = index.digest("ada@example.org".to_slice)
    value.size.should eq(Punch::KeyRing::BlindIndex::SIZE)
    value[0, 5].should eq(Bytes[1, 0, 0, 0, 1])
    index.digest("ada@example.org".to_slice).should eq(value)
    index.digest("ada@example.net".to_slice).should_not eq(value)
    ring.blind_index("blind_index:customers.name_index").digest("ada@example.org".to_slice).should_not eq(value)
    KeyRingSpec.ring(KeyRingSpec.key(2)).blind_index("blind_index:customers.email_index").digest("ada@example.org".to_slice)[5, 32].should_not eq(value[5, 32])
    # HMAC-SHA256 under a key of its own, derived for blind indexes only.
    key = Punch::Crypto::HKDF.derive(Bytes.new(32) { |position| (position * 7 + 1).to_u8 }, "blind-index:hmac-sha256:v1:blind_index:customers.email_index")
    value[5, 32].should eq(OpenSSL::HMAC.digest(:sha256, key, "ada@example.org"))
  end

  it "hashes under every key for lookups, the signing key first, and tells which key wrote a value" do
    old = KeyRingSpec.ring(KeyRingSpec.key(1)).blind_index("b").digest("x".to_slice)
    ring = KeyRingSpec.ring(KeyRingSpec.key(3, pending: true), KeyRingSpec.key(2), KeyRingSpec.key(1))
    digests = ring.blind_index("b").digests("x".to_slice)
    digests.map { |digest| Punch::KeyRing::BlindIndex.key_id(digest) }.should eq([2_u32, 3_u32, 1_u32])
    digests.should contain(old)
    ring.blind_index("b").digest("x".to_slice).should eq(digests.first)
    ring.blind_index("b").matches?(old, "x".to_slice).should be_true
    ring.blind_index("b").matches?(old, "y".to_slice).should be_false
    KeyRingSpec.ring(KeyRingSpec.key(2)).blind_index("b").matches?(old, "x".to_slice).should be_false
    Punch::KeyRing::BlindIndex.key_id(old[0, 36]).should be_nil
    ring.blind_index("b").should be(ring.blind_index("b"))
  end
end

describe "a key ring in credentials" do
  it "loads secret_key_base as Punch::KeyRing.current, recorded as a secret" do
    ring = KeyRingSpec.ring(KeyRingSpec.key(1))
    source = Punch::Credentials::Source.open("test", nil, {"SECRET_KEY_BASE" => ring.to_text})
    app = KeyRingSpec::App.load(source).as(KeyRingSpec::App)
    app.secret_key_base.signing.id.should eq(1)
    source.entries.first.secret.should be_true
    source.entries.first.value.should be_nil
    Punch::Spec.credentials(KeyRingSpec::App, "secret_key_base: |\n  #{ring.to_text}\n")
    Punch::KeyRing.current.to_text.should eq(ring.to_text)
  end

  it "reports a malformed ring by position only" do
    text = KeyRingSpec.key(1).to_text
    source = Punch::Credentials::Source.open("test", nil, {"SECRET_KEY_BASE" => "#{text},#{text[0..-3]}"})
    problems = KeyRingSpec::App.load(source).as(Array(String))
    problems.should eq(["secret_key_base from SECRET_KEY_BASE is not valid: invalid_key_ring (reason malformed, entry 2)"])
  end
end
