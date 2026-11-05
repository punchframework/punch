require "../spec_helper"

describe Punch::Crypto::HKDF do
  # RFC 5869, test cases 1 and 3.
  it "matches RFC 5869 test case 1" do
    prk = Punch::Crypto::HKDF.extract("000102030405060708090a0b0c".hexbytes, ("0b" * 22).hexbytes)
    prk.hexstring.should eq("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
    Punch::Crypto::HKDF.expand(prk, "f0f1f2f3f4f5f6f7f8f9".hexbytes, 42).hexstring.should eq(
      "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
  end

  it "matches RFC 5869 test case 3 (empty salt and info)" do
    prk = Punch::Crypto::HKDF.extract(Bytes.empty, ("0b" * 22).hexbytes)
    Punch::Crypto::HKDF.expand(prk, Bytes.empty, 42).hexstring.should eq(
      "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
  end

  it "derives a different key for every purpose" do
    root = Bytes.new(32, 7_u8)
    a = Punch::Crypto::HKDF.derive(root, "aes-256-gcm:v1:credentials")
    b = Punch::Crypto::HKDF.derive(root, "aes-256-gcm:v1:column:customers.email")
    a.size.should eq(32)
    a.should_not eq(b)
    Punch::Crypto::HKDF.derive(root, "aes-256-gcm:v1:credentials").should eq(a)
  end
end

describe Punch::Crypto::AESGCM do
  # McGrew and Viega, "The Galois/Counter Mode of Operation", test case 14.
  it "opens GCM test case 14" do
    plain = Punch::Crypto::AESGCM.open(Bytes.new(32), Bytes.new(12), "cea7403d4d606b6e074ec5d3baf39d18".hexbytes,
      "d0d1c8a799996bf0265b98b5d48ab919".hexbytes)
    plain.should eq(Bytes.new(16))
  end

  it "refuses a truncated tag, which OpenSSL alone would accept" do
    tag = "d0d1c8a799996bf0265b98b5d48ab919".hexbytes
    ciphertext = "cea7403d4d606b6e074ec5d3baf39d18".hexbytes
    Punch::Crypto::AESGCM.open(Bytes.new(32), Bytes.new(12), ciphertext, tag[0, 4]).should be_nil
  end

  it "round-trips with a fresh nonce each time and rejects every changed byte" do
    key = Punch::Crypto.random_key
    sealed = Punch::Crypto::AESGCM.seal(key, "attack at dawn".to_slice)
    Punch::Crypto::AESGCM.seal(key, "attack at dawn".to_slice).nonce.should_not eq(sealed.nonce)
    Punch::Crypto::AESGCM.open(key, sealed.nonce, sealed.ciphertext, sealed.tag).should eq("attack at dawn".to_slice)
    {sealed.nonce, sealed.ciphertext, sealed.tag}.each do |part|
      part.size.times do |index|
        part[index] ^= 1
        Punch::Crypto::AESGCM.open(key, sealed.nonce, sealed.ciphertext, sealed.tag).should be_nil
        part[index] ^= 1
      end
    end
    Punch::Crypto::AESGCM.open(Punch::Crypto.random_key, sealed.nonce, sealed.ciphertext, sealed.tag).should be_nil
  end

  it "refuses keys of the wrong size" do
    expect_raises(ArgumentError, /32 bytes/) { Punch::Crypto::AESGCM.seal(Bytes.new(16), Bytes.empty) }
  end
end
