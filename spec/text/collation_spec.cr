require "../spec_helper"

private DE = Punch::Text::Collation::BUILTIN.find!(&.name.==("de"))

private def sorted(words : Array(String)) : Array(String)
  words.sort { |a, b| DE.compare.call(a.to_slice, b.to_slice) }
end

private def compare(a : String | Bytes, b : String | Bytes) : Int32
  DE.compare.call(a.is_a?(String) ? a.to_slice : a, b.is_a?(String) ? b.to_slice : b)
end

describe Punch::Text::Collation do
  it "has the Latin languages, one name each, with one version" do
    Punch::Text::Collation::BUILTIN.map(&.name).should eq(%w[de en es fr it nl pt])
    Punch::Text::Collation::BUILTIN.map(&.version).uniq!.should eq(["punch-latin-1/unicode-#{Unicode::VERSION}"])
    expect_raises(ArgumentError, "lowercase identifiers") { Punch::Text::Collation.new("De-AT", "1", ->(a : Bytes, b : Bytes) { a <=> b }) }
  end

  describe "Latin" do
    it "sorts umlauts and accents with their letters, not after z" do
      sorted(%w[zulu Ärger apfel Zebra éclair Öl ober]).should eq(%w[apfel Ärger éclair ober Öl Zebra zulu])
    end

    it "breaks ties by accent, then case (lowercase first), then bytes" do
      sorted(%w[Äpfel apfel äpfel Apfel]).should eq(%w[apfel Apfel äpfel Äpfel])
      sorted(%w[Straße strasse Strasse]).should eq(%w[strasse Strasse Straße])
      compare("Café", "Cafe").should eq(1)
    end

    it "orders spaces, punctuation, digits, then letters; other scripts after Latin" do
      sorted(["b", "Москва", "2", " a", "-a", "a", "Ωmega"]).should eq([" a", "-a", "2", "a", "b", "Ωmega", "Москва"])
    end

    it "expands letters that do not decompose" do
      sorted(%w[oz Øre oa]).should eq(%w[oa Øre oz])
      sorted(%w[Mueller Müller Muffel]).should eq(%w[Mueller Muffel Müller])
      compare("Æsop", "aesop").should eq(1)
      compare("Æsop", "aesoq").should eq(-1)
    end

    it "is equal only for identical bytes, so unique indexes stay strict" do
      compare("Ärger", "Ärger").should eq(0)
      compare("Ärger", "ärger").should_not eq(0)
      # NFC and NFD forms of é: different values, as without a collation.
      compare("é", "é").should_not eq(0)
    end

    it "orders invalid UTF-8 without raising" do
      bad = Bytes[0x61, 0xff, 0x62]
      compare(bad, "ab").should_not eq(0)
      compare(bad, bad).should eq(0)
      compare(Bytes[0xe2, 0x82], "a").should eq(-1)
    end

    it "is a total order: antisymmetric and transitive on random words" do
      alphabet = "aAäÄbBeéÉoöøsßzZ 1-".chars
      random = Random.new(42)
      words = Array.new(300) { String.build { |io| random.rand(0..6).times { io << alphabet.sample(random) } } }
      words.each_slice(3) do |slice|
        a, b, c = slice[0], slice[1]? || "", slice[2]? || ""
        compare(a, b).sign.should eq(-compare(b, a).sign)
        if compare(a, b) <= 0 && compare(b, c) <= 0
          compare(a, c).should be <= 0
        end
      end
      sorted(words).each_cons_pair { |x, y| compare(x, y).should be <= 0 }
    end

    it "gives the same order from many fibers on several threads" do
      words = %w[zulu Ärger apfel Zebra éclair Öl ober Straße strasse Ωmega]
      expected = sorted(words)
      results = Channel(Array(String)).new(32)
      32.times { spawn { results.send(sorted(words.shuffle)) } }
      32.times { results.receive.should eq(expected) }
    end
  end
end
