require "../spec_helper"
require "./fixture/app/translations.gen"

private def locale(tag : String, catalog : Punch::I18n::Catalog = Punch::I18n::OWN) : Punch::Locale
  catalog.locale?(tag) || raise "no locale #{tag}"
end

private def money(value : Int64) : Punch::Money
  Punch::Money.parse(value).as(Punch::Money)
end

private def currency(code : String) : Punch::Currency
  Punch::Currency.parse(code).as(Punch::Currency)
end

private def plural(rule : Punch::I18n::Plural::Rule, numbers : Enumerable(Int32)) : Array(String)
  numbers.map { |number| Punch::I18n::Plural.category(rule, number).to_s.downcase }
end

describe Punch::I18n do
  it "fills in %{name}, keeps unknown names, and writes %%{ as %{" do
    Punch::I18n.interpolate("Hello, %{name}! %{other} %%{literal} 100%", {name: "Ada"}).should eq("Hello, Ada! %{other} %{literal} 100%")
    Punch::I18n.interpolate("über %{n} Größe", {"n" => 3_i64} of String => Punch::Invalid::Param).should eq("über 3 Größe")
    Punch::I18n.interpolate("no names", {name: "x"}).should eq("no names")
  end

  it "negotiates Accept-Language by q, exact tag, then language" do
    Punch::I18n.negotiate(nil).code.should eq("en")
    Punch::I18n.negotiate("de").code.should eq("de")
    Punch::I18n.negotiate("de-AT,de;q=0.9,en;q=0.8").code.should eq("de")
    Punch::I18n.negotiate("fr-CH, fr;q=0.9, de;q=0.5, en;q=0.4").code.should eq("de")
    Punch::I18n.negotiate("en;q=0.5, de;q=0.8").code.should eq("de")
    Punch::I18n.negotiate("de;q=0, en").code.should eq("en")
    Punch::I18n.negotiate("fr, *;q=0.1").code.should eq("en")
    Punch::I18n.negotiate("garbage;;;").code.should eq("en")
  end

  it "finds a stored tag, its language, or the default" do
    Punch::I18n.locale("de").code.should eq("de")
    Punch::I18n.locale("DE-at").code.should eq("de")
    Punch::I18n.locale("fr").code.should eq("en")
    Punch::I18n.locale(nil).code.should eq("en")
  end

  it "renders Punch's messages for error and problem codes" do
    locale("de").error?("too_long", {"max" => 64_i64} of String => Punch::Invalid::Param).should eq("Darf höchstens 64 Zeichen lang sein.")
    locale("en").problem?("rate_limited", {"retry_after" => 3_i64} of String => Punch::Invalid::Param).should eq("Too many requests. Please try again in 3 seconds.")
    locale("en").error?("no_such_code").should be_nil
    locale("en").field("company_name").should eq("Company name")
    locale("en").field("customer_id").should eq("Customer")
  end

  it "knows every error code Punch's own code produces, in English and German" do
    codes = Dir.glob("#{__DIR__}/../../src/**/*.cr").flat_map do |file|
      File.read(file).scan(/Invalid\.new\("([a-z_0-9]+)"/).map(&.[1])
    end.to_set - {"invalid_key_ring", "invalid_public_id_key", "invalid_queue", "invalid_store", "invalid_provider", "invalid_invoice_number"}
    %w[en de].each do |tag|
      missing = codes.reject { |code| locale(tag).error?(code) }
      missing.should eq([] of String)
    end
  end

  describe "plural rules" do
    it "covers one/other, fr's 0 and 1, and the Slavic rules" do
      plural(:one_other, 0..2).should eq(%w[other one other])
      plural(:zero_one_other, 0..2).should eq(%w[one one other])
      plural(:polish, [1, 2, 5, 12, 22, 25, 112]).should eq(%w[one few many many few many many])
      plural(:east_slavic, [1, 2, 5, 11, 21, 22, 111]).should eq(%w[one few many many one few many])
      plural(:west_slavic, [1, 3, 5]).should eq(%w[one few other])
      plural(:arabic, [0, 1, 2, 3, 11, 100]).should eq(%w[zero one two few many other])
      plural(:none, 0..2).should eq(%w[other other other])
    end

    it "names the forms each rule needs" do
      Punch::I18n::Plural.categories(:one_other).map(&.to_s).should eq(%w[One Other])
      Punch::I18n::Plural.categories(:polish).map(&.to_s).should eq(%w[One Few Many Other])
      Punch::I18n::Plural.rule?("pt-BR").should eq(Punch::I18n::Plural::Rule::ZeroOneOther)
      Punch::I18n::Plural.rule?("pt-PT").should eq(Punch::I18n::Plural::Rule::OneOther)
      Punch::I18n::Plural.rule?("tlh").should be_nil
    end
  end

  describe "formats" do
    time = Time.utc(2026, 3, 5, 14, 7, 9)

    it "writes dates and times with the locale's patterns and names" do
      locale("en").date(time).should eq("2026-03-05")
      locale("de").date(time).should eq("05.03.2026")
      locale("en").date(time, :long).should eq("March 5, 2026")
      locale("de").date(time, :long).should eq("5. März 2026")
      locale("de").date(time, :short).should eq("5. Mär")
      locale("de").time(time).should eq("Donnerstag, 05. März 2026, 14:07 Uhr")
      locale("de").strftime(time, "%A %^b %% %Y").should eq("Donnerstag MÄR % 2026")
      locale("en").strftime(time, "%I %p").should eq("02 pm")
    end

    it "writes numbers with the locale's marks" do
      locale("en").number(1234567).should eq("1,234,567")
      locale("de").number(1234567).should eq("1.234.567")
      locale("de").number(1234.5).should eq("1.234,50")
      locale("en").number(1234.5).should eq("1,234.500")
      locale("en").number(-0.126, 2).should eq("-0.13")
    end

    it "writes money with the currency's minor unit and the locale's pattern" do
      locale("en").money(money(125000), currency("EUR")).should eq("€1,250.00")
      locale("de").money(money(125000), currency("EUR")).should eq("1.250,00 €")
      locale("de").money(money(-5), currency("EUR")).should eq("-0,05 €")
      locale("en").money(money(1250), currency("JPY")).should eq("¥1,250")
      locale("en").money(money(1250), currency("KWD")).should eq("KWD1.250")
      locale("de").money(money(100), currency("CHF")).should eq("1,00 CHF")
    end
  end

  describe "generated accessors" do
    catalog = Fixture::Translations::CATALOG

    it "renders messages and plurals in each locale, with the default as fallback" do
      en, de = locale("en", catalog).t, locale("de", catalog).t
      en.greeting(name: "Ada").should eq("Hello, Ada!")
      de.greeting(name: "Ada").should eq("Hallo, Ada!")
      en.inbox.messages(count: 0, folder: "INBOX").should eq("No messages")
      en.inbox.messages(count: 1, folder: "INBOX").should eq("1 message")
      en.inbox.messages(count: 3, folder: "INBOX").should eq("3 messages in INBOX")
      de.inbox.messages(count: 0, folder: "INBOX").should eq("0 Nachrichten in INBOX")
      de.inbox.messages(count: 1, folder: "INBOX").should eq("1 Nachricht")
    end

    it "lets the app override Punch's messages and add codes and labels" do
      en, de = locale("en", catalog), locale("de", catalog)
      en.error?("blank").should eq("Please fill this in.")
      de.error?("blank").should eq("Darf nicht leer sein.")
      de.error?("wrong_amount", {"total" => "12,00 €"} of String => Punch::Invalid::Param).should eq("Stimmt nicht mit der Summe von 12,00 € überein.")
      de.problem?("already_sent").should eq("Das wurde schon gesendet.")
      de.field("company_name").should eq("Firma")
      de.date(Time.utc(2026, 1, 2)).should eq("02.01.2026")
    end
  end
end

# The fixture's accessors are compiled here; `Locale#t` is the app's, as
# `Punch.translations` would declare it.
struct Punch::Locale
  def t : Fixture::Translations
    Fixture::Translations.new(self)
  end
end
