require "./project"
require "../../i18n_gen"

module Punch::CLI::Commands
  # Writes the app's translations from `config/locales/`: typed accessors
  # and the catalog, next to the file that declares `Punch.translations`. In
  # Punch's own repository it writes Punch's catalog. With `--check`, writes
  # nothing and fails when the file is stale, a locale lacks a key or uses
  # other `%{…}` names, a plural lacks a form its rule needs, or an error or
  # problem code has no message.
  class I18nGenerate < Command
    command "i18n:generate", "Generate typed translations from config/locales/*.yml; --check also fails on gaps between locales and codes without messages"

    struct Result
      include Report

      def initialize(@state : String, @result : I18nGen::Result)
      end

      def to_text(io : IO) : Nil
        result = @result
        io.puts "#{@state.ljust(9)} #{result.output.path}"
        io.puts "#{result.keys} keys in #{result.locales.join(", ")} (default #{result.locales.first})."
        unless result.findings.empty?
          io.puts "To fix (`punch check` fails on these):"
          result.findings.each { |finding| io.puts "  #{finding}" }
        end
        unless result.unused.empty?
          io.puts "Not found in a call (`t.….key`), maybe unused:"
          result.unused.each { |key, location| io.puts "  #{key} (#{location})" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", @result.output.path
          json.field "state", @state
          json.field "locales", @result.locales
          json.field "keys", @result.keys
          json.field "findings" do
            json.array do
              @result.findings.each do |finding|
                json.object { json.field "location", finding.location.to_s; json.field "message", finding.message }
              end
            end
          end
          json.field "unused" do
            json.array { @result.unused.each { |key, location| json.object { json.field "key", key; json.field "location", location.to_s } } }
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      check = args.delete("--check")
      if extra = args.first?
        return Failure.usage("unexpected_argument", "'punch i18n:generate' takes --check, not '#{extra}'.")
      end

      project = Project.load
      return project if project.is_a?(Failure)

      sources = I18nGenerate.sources
      declaration = I18nGen.declaration(sources)
      if declaration.nil? && project.name != "punch"
        return Failure.new("no_translations", "No `Punch.translations` declaration in app/ or src/. Declare the type to generate once, such as `Punch.translations MyApp::Translations, default: \"en\"` in app/translations.cr (lib/punch/docs/translations.md).")
      end

      result = I18nGen.run(I18nGen::Config.new(declaration: declaration, sources: sources))
      output = result.output
      current = File.exists?(output.path) ? File.read(output.path) : nil
      return I18nGenerate.check(result, current != output.content) if check
      return Result.new("unchanged", result) if current == output.content

      Dir.mkdir_p(File.dirname(output.path))
      File.write(output.path, output.content)
      Result.new("written", result)
    rescue ex : QueryGen::Errors
      Failure.new("generate_failed", ex.message || "generation failed")
    end

    # Whether `punch check` runs this: an app with locale files, and Punch
    # itself, whose own catalog is generated too.
    def self.applies?(project : Project) : Bool
      Dir.exists?(I18nGen::DIRECTORY) || project.name == "punch"
    end

    # `--check`: fails when the file is *stale* or the translations have
    # gaps.
    def self.check(result : I18nGen::Result, stale : Bool) : Report | Failure
      return Result.new("current", result) if !stale && result.findings.empty?

      message = String.build do |io|
        io << result.output.path << " does not match the locale files. Run 'punch i18n:generate' and commit the result; never edit it by hand." if stale
        unless result.findings.empty?
          io << "\n" if stale
          io << "The translations have gaps:\n" << result.findings.join('\n') { |finding| "  #{finding}" }
        end
      end
      Failure.new("translations_incomplete", message, details: JSON.parse(Result.new(stale ? "stale" : "current", result).to_json))
    end

    # The app's Crystal files the generator reads for the declaration,
    # codes, and calls: `app/` and `src/`, without generated files.
    def self.sources : Array(String)
      Dir.glob("{app,src}/**/*.cr").reject(&.ends_with?(".gen.cr")).sort!
    end
  end
end
