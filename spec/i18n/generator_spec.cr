require "../spec_helper"
require "../../src/punch/i18n_gen"

private FIXTURE = "#{__DIR__}/fixture"

# Runs the generator in *directory*, as `punch i18n:generate` does there.
# Examples run one at a time, so changing the working directory is safe.
private def generate(directory : String = FIXTURE) : Punch::I18nGen::Result
  Dir.cd(directory) do
    sources = Dir.glob("{app,src}/**/*.cr").reject(&.ends_with?(".gen.cr")).sort!
    Punch::I18nGen.run(Punch::I18nGen::Config.new(declaration: Punch::I18nGen.declaration(sources), sources: sources))
  end
end

# A throwaway app with *files*: locale files and Crystal sources. The
# declaration is added unless *files* has its own.
private def with_app(files : Hash(String, String), & : String ->) : Nil
  directory = File.tempname("punch-i18n")
  begin
    files = {"app/translations.cr" => %(Punch.translations App::Translations, default: "en")}.merge(files)
    files.each do |path, content|
      Dir.mkdir_p(File.dirname(File.join(directory, path)))
      File.write(File.join(directory, path), content)
    end
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def findings(files : Hash(String, String)) : Array(String)
  lines = [] of String
  with_app(files) { |directory| lines = generate(directory).findings.map(&.message) }
  lines
end

private def errors(files : Hash(String, String)) : Array(String)
  lines = [] of String
  with_app(files) do |directory|
    lines = expect_raises(Punch::QueryGen::Errors) { generate(directory) }.errors.map(&.to_s)
  end
  lines
end

describe Punch::I18nGen do
  it "keeps the fixture's committed file current" do
    result = generate
    File.read(File.join(FIXTURE, result.output.path)).should eq(result.output.content)
    result.locales.should eq(%w[en de])
    result.findings.should be_empty
    result.unused.map(&.[0]).should eq(["inbox.title"])
  end

  it "keeps Punch's own catalog current" do
    root = "#{__DIR__}/../.."
    result = Dir.cd(root) { Punch::I18nGen.run(Punch::I18nGen::Config.new) }
    result.output.path.should eq("src/punch/i18n/own.gen.cr")
    File.read(File.join(root, result.output.path)).should eq(result.output.content)
    result.findings.should be_empty
  end

  it "reports keys missing in a locale, other %{…} names, and keys only another locale has" do
    found = findings({
      "config/locales/en.yml" => %(en:\n  hello: "Hello %{name}"\n  bye: "Bye"\n),
      "config/locales/de.yml" => %(de:\n  hello: "Hallo %{nom}"\n  extra: "Mehr"\n),
    })
    found.should contain("bye is missing in de")
    found.should contain("de.hello uses %{nom}, but en uses %{name}")
    found.should contain("de.extra is not in en, the default locale")
  end

  it "reports plural forms a locale's rule needs or never uses" do
    found = findings({
      "config/locales/en.yml" => %(en:\n  items:\n    one: "%{count} item"\n    other: "%{count} items"\n),
      "config/locales/de.yml" => %(de:\n  items:\n    one: "%{count} Ding"\n    few: "%{count} Dinge"\n    other: "%{count} Dinge"\n),
      "config/locales/pl.yml" => %(pl:\n  items:\n    one: "%{count} rzecz"\n    other: "%{count} rzeczy"\n),
    })
    found.should contain("de.items has plural forms OneOther never uses: few")
    found.should contain("pl.items needs the plural forms few, many (rule Polish)")
  end

  it "groups Punch's own keys a locale lacks into one finding" do
    found = findings({
      "config/locales/en.yml" => %(en:\n  hello: "Hello"\n),
      "config/locales/fr.yml" => %(fr:\n  hello: "Bonjour"\n),
    })
    found.size.should eq(1)
    found[0].should start_with("fr lacks #{Punch::I18n::OWN.entries.size} of Punch's keys (punch.language_name")
  end

  it "reports error and problem codes in the app's code that have no message" do
    found = findings({
      "config/locales/en.yml" => %(en:\n  errors:\n    known: "Known"\n),
      "app/codes.cr"          => <<-CRYSTAL,
        X = Punch::Invalid.new("known")
        Y = Punch::Invalid.new("unknown_code", max: 3)
        Z = Invalid.new("too_long", max: 3)

        @[Punch::Status(409)]
        struct AlreadyDone
        end

        @[Punch::Status(410)]
        struct GonePage
          include Punch::Component
        end

        @[Punch::Status(201)]
        struct Made
        end
        CRYSTAL
    })
    found.should eq([
      "the error code unknown_code has no message: add errors.unknown_code to the locale files",
      "the problem already_done (AlreadyDone) has no message: add problems.already_done to the locale files",
    ])
  end

  it "refuses keys that cannot be methods, unknown locales, and duplicates" do
    errors({"config/locales/en.yml" => %(en:\n  Bad-Key: "x"\n)}).first.should contain("`Bad-Key` cannot be a method name")
    errors({"config/locales/en.yml" => %(en:\n  class: "x"\n)}).first.should contain("`class` cannot be a method name")
    errors({"config/locales/en.yml" => %(en:\n  a: "%{x-y}"\n)}).first.should contain("`%{x-y}` cannot be an argument name")
    errors({"config/locales/en.yml" => %(en:\n  a: "x"\n), "config/locales/tlh.yml" => %(tlh:\n  a: "y"\n)}).first.should contain("no plural rules for the locale tlh")
    errors({"config/locales/en.yml" => %(en:\n  a: "x"\n), "config/locales/more/en.yml" => %(en:\n  a: "y"\n)}).first.should contain("a is also defined at config/locales/en.yml:2:6")
    errors({"config/locales/de.yml" => %(de:\n  a: "x"\n)}).first.should contain("the default locale is en, but config/locales has no file for it")
    errors({"config/locales/en.yml" => %(en: [1, 2\n)}).first.should contain("does not parse")
  end

  it "takes the default locale and the type from the declaration" do
    with_app({
      "app/translations.cr"   => %(Punch.translations Shop::Texts, default: "de"),
      "config/locales/de.yml" => %(de:\n  hello: "Hallo"\n),
      "config/locales/en.yml" => %(en:\n  hello: "Hello"\n),
    }) do |directory|
      result = generate(directory)
      result.locales.should eq(%w[de en])
      result.output.path.should eq("app/translations.gen.cr")
      result.output.content.should contain("struct Shop::Texts\n  DEFAULT = \"de\"")
      result.output.content.should contain(%(# "Hallo"\n  def hello : String))
    end
  end
end
