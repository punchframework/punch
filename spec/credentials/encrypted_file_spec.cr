require "../spec_helper"

private def key(byte : Int32 = 1) : Punch::Credentials::MasterKey
  Punch::Credentials::MasterKey.new(Bytes.new(32, byte.to_u8), "spec")
end

describe Punch::Credentials::EncryptedFile do
  it "round-trips the text as one line of Base64" do
    text = Punch::Credentials::EncryptedFile.encrypt("stripe:\n  secret_key: sk_live_ü\n", key)
    text.lines.size.should eq(1)
    text.should_not contain("sk_live")
    Punch::Credentials::EncryptedFile.decrypt(text, key).should eq("stripe:\n  secret_key: sk_live_ü\n")
  end

  it "tells a wrong key from a damaged file" do
    text = Punch::Credentials::EncryptedFile.encrypt("a: 1", key(1))
    Punch::Credentials::EncryptedFile.decrypt(text, key(2)).should eq(Punch::Credentials::EncryptedFile::Error::WrongKey)
  end

  it "rejects every changed byte" do
    message = Base64.decode(Punch::Credentials::EncryptedFile.encrypt("a: 1", key))
    message.size.times do |index|
      message[index] ^= 1
      outcome = Punch::Credentials::EncryptedFile.decrypt(Base64.strict_encode(message), key)
      outcome.should be_a(Punch::Credentials::EncryptedFile::Error)
      message[index] ^= 1
    end
    Punch::Credentials::EncryptedFile.decrypt(Base64.strict_encode(message), key).should eq("a: 1")
  end

  it "rejects truncations and text that is not a credentials file" do
    message = Base64.decode(Punch::Credentials::EncryptedFile.encrypt("a: 1", key))
    (0...message.size).each do |size|
      Punch::Credentials::EncryptedFile.decrypt(Base64.strict_encode(message[0, size]), key).should be_a(Punch::Credentials::EncryptedFile::Error)
    end
    Punch::Credentials::EncryptedFile.decrypt("stripe: plain text", key).should eq(Punch::Credentials::EncryptedFile::Error::Malformed)
  end

  it "names the key's origin in messages, never the key" do
    error = Punch::Credentials::EncryptedFile::Error::WrongKey
    error.message("config/credentials/production.yml.enc", key).should eq(
      "config/credentials/production.yml.enc was encrypted with another key than spec")
  end
end

describe Punch::Credentials::MasterKey do
  it "parses 64 hexadecimal characters and prints no key material" do
    generated = Punch::Credentials::MasterKey.generate("x")
    parsed = Punch::Credentials::MasterKey.parse(generated.to_text + "\n", "config/credentials/test.key")
    parsed = parsed.as(Punch::Credentials::MasterKey)
    parsed.id.should eq(generated.id)
    parsed.to_s.should_not contain(generated.to_text)
    parsed.inspect.should_not contain(generated.to_text)
    parsed.origin.should eq("config/credentials/test.key")
  end

  it "reports a malformed key without its text" do
    problem = Punch::Credentials::MasterKey.parse("deadbeef-secret", "PUNCH_MASTER_KEY")
    problem.should eq("PUNCH_MASTER_KEY must hold 64 hexadecimal characters (a key from 'punch creds:init')")
  end

  it "prefers PUNCH_MASTER_KEY over the key file" do
    directory = File.tempname("punch-creds")
    Dir.mkdir_p(directory)
    begin
      from_file = Punch::Credentials::MasterKey.generate("file")
      File.write(File.join(directory, "test.key"), from_file.to_text)
      from_env = Punch::Credentials::MasterKey.generate("env")
      resolved = Punch::Credentials::MasterKey.resolve("test", {"PUNCH_MASTER_KEY" => from_env.to_text}, directory)
      resolved.as(Punch::Credentials::MasterKey).id.should eq(from_env.id)
      resolved = Punch::Credentials::MasterKey.resolve("test", {} of String => String, directory)
      resolved.as(Punch::Credentials::MasterKey).id.should eq(from_file.id)
      Punch::Credentials::MasterKey.resolve("production", {} of String => String, directory).should be_nil
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
