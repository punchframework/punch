require "../spec_helper"

describe Punch::Text do
  it "lowercases and uppercases beyond ASCII" do
    Punch::Text.lower("ÄRGER ÉCLAIR Ωmega").should eq("ärger éclair ωmega")
    Punch::Text.upper("straße ärger").should eq("STRASSE ÄRGER")
  end

  describe ".like?" do
    it "matches % and _ case-insensitively in every script" do
      Punch::Text.like?("Ä%", "ärger").should be_true
      Punch::Text.like?("_rger", "Ärger").should be_true
      Punch::Text.like?("%ΩMEGA", "das ωmega").should be_true
      Punch::Text.like?("%x%y%", "axbyc").should be_true
      Punch::Text.like?("%x%y%", "aybxc").should be_false
      Punch::Text.like?("", "").should be_true
      Punch::Text.like?("%", "").should be_true
      Punch::Text.like?("_", "").should be_false
    end

    it "keeps accents apart" do
      Punch::Text.like?("a%", "ärger").should be_false
    end

    it "makes the escaped character literal" do
      Punch::Text.like?("%50!%%", "50% off", '!').should be_true
      Punch::Text.like?("%50!%%", "500 off", '!').should be_false
      Punch::Text.like?("a!_c", "a_c", '!').should be_true
      Punch::Text.like?("a!_c", "abc", '!').should be_false
      Punch::Text.like?("a!!", "a!", '!').should be_true
      Punch::Text.like?("ab!", "ab", '!').should be_false
    end

    it "backtracks without recursion on long inputs" do
      Punch::Text.like?("%a%a%a%a%b", "a" * 2000).should be_false
    end
  end
end
