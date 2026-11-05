require "./project"
require "../../openapi/diff"

module Punch::CLI::Commands
  # Writes `openapi.json` for the app in the current directory: builds the
  # first target of `shard.yml` with `-Dpunch_openapi`, runs its
  # `openapi:derive`, adds descriptions from the doc comments
  # (`crystal docs --format json`), and writes the document. With `--check`,
  # writes nothing and fails when the committed file differs.
  class OpenAPIWrite < Command
    command "openapi", "Derive openapi.json from the app's operations; --check compares instead"

    FILE = "openapi.json"

    struct Result
      include Report

      def initialize(@state : String, @document : JSON::Any)
      end

      def to_text(io : IO) : Nil
        operations = @document["paths"].as_h.sum(&.[1].as_h.size)
        io.puts "#{@state.ljust(9)} #{FILE} (#{operations} operations, #{@document["components"]["schemas"].as_h.size} schemas)"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", FILE
          json.field "state", @state
          json.field "operations", @document["paths"].as_h.sum(&.[1].as_h.size)
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      check = args.delete("--check")
      return Failure.usage("unexpected_argument", "'punch openapi' takes only --check.") unless args.empty?

      project = Project.load
      return project if project.is_a?(Failure)

      name, version, main = project.name, project.version, project.main
      binary = project.derivation
      return binary if binary.is_a?(Failure)

      output = IO::Memory.new
      derived = IO::Memory.new
      status = Process.run(binary, ["openapi:derive", name, version, "--json"], output: derived, error: output)
      return Failure.new("derive_failed", "#{binary} openapi:derive failed:\n#{output}#{derived}") unless status.success?

      result = JSON.parse(derived.to_s)
      docs = docs(main, name, version) || return Failure.new("docs_failed", "crystal docs #{main} failed; the descriptions come from it.")
      document = OpenAPIWrite.describe(result, docs)
      text = document.to_pretty_json + "\n"
      current = File.exists?(FILE) ? File.read(FILE) : nil
      if check
        return Result.new("current", document) if current == text

        return Failure.new("stale_openapi", "#{FILE} does not match the operations. Run 'punch openapi' and commit the result; never edit it by hand.")
      end
      return Result.new("unchanged", document) if current == text

      File.write(FILE, text)
      Result.new("written", document)
    end

    # The doc comments of every type and method, by full type name.
    private def docs(main : String, name : String, version : String) : Hash(String, JSON::Any)?
      # With --format json, crystal docs writes the index to stdout.
      output = IO::Memory.new
      # crystal docs documents only types defined in the directories of its
      # input files, so the files under app/ are inputs too. It counts every
      # input as required already, so main's own `require`s skip them and
      # each is read where it stands in the list: they go in the order main
      # requires them, or a type is used before the file defining it.
      inputs = [main] + app_files(main)
      status = Process.run("crystal", ["docs"] + inputs + ["--format", "json", "--project-name", name, "--project-version", version],
        output: output, error: Process::Redirect::Close)
      return unless status.success?

      types = {} of String => JSON::Any
      collect(JSON.parse(output.to_s)["program"], types)
      types
    end

    # The `.cr` files under app/ in the order *main* requires them, then
    # any it does not require, sorted.
    private def app_files(main : String) : Array(String)
      all = Dir.glob("app/**/*.cr").sort!
      output = IO::Memory.new
      status = Process.run("crystal", ["tool", "dependencies", main, "--format", "flat"], output: output, error: Process::Redirect::Close)
      return all unless status.success?

      required = output.to_s.lines.map(&.strip).select { |path| all.includes?(path) }.uniq!
      required + (all - required)
    end

    private def collect(type : JSON::Any, types : Hash(String, JSON::Any)) : Nil
      types[type["full_name"].as_s] = type
      type["types"]?.try(&.as_a?).try &.each { |nested| collect(nested, types) }
    end

    # The first sentence of the first paragraph, on one line: doc comments
    # wrap, a summary does not.
    def self.summary(text : String) : String
      paragraph = text.split(/\n\s*\n/, 2).first.split.join(' ')
      paragraph[/\A.+?[.!?](?=\s|\z)/]? || paragraph
    end

    # Adds descriptions: a schema gets its type's doc comment, a property
    # its getter's, an operation its type's (its first sentence as `summary`).
    def self.describe(result : JSON::Any, docs : Hash(String, JSON::Any)) : JSON::Any
      document = result["document"]
      schemas = document["components"]["schemas"].as_h
      result["types"].as_h.each do |schema_name, type_name|
        type = docs[type_name.as_s]? || next
        schema = schemas[schema_name]?.try(&.as_h?) || next
        if (text = doc(type)) && !schema.has_key?("$ref")
          schemas[schema_name] = JSONSchema.set(JSON::Any.new(schema), "description", JSON::Any.new(text))
        end
        fields = result["fields"][schema_name]?.try(&.as_h?) || next
        properties = schemas[schema_name]["properties"]?.try(&.as_h?) || next
        fields.each do |key, field|
          method = type["instance_methods"]?.try(&.as_a.find { |entry| entry["name"].as_s.in?(field.as_s, "#{field.as_s}?") })
          text = method.try { |entry| doc(entry) } || next
          property = properties[key]? || next
          properties[key] = JSONSchema.set(property, "description", JSON::Any.new(text))
        end
      end
      paths = document["paths"].as_h
      paths.each_value do |methods|
        described = methods.as_h.compact_map do |method, operation|
          type = result["operations"][operation["operationId"].as_s]?.try { |name| docs[name.as_s]? } || next
          text = doc(type) || next
          entry = JSONSchema.set(operation, "summary", JSON::Any.new(summary(text)))
          {method, text.lines.size > 1 ? JSONSchema.set(entry, "description", JSON::Any.new(text)) : entry}
        end
        described.each { |method, entry| methods.as_h[method] = entry }
      end
      document
    end

    private def self.doc(entry : JSON::Any) : String?
      entry["doc"]?.try(&.as_s?).try(&.strip).presence
    end
  end

  # Reports the breaking changes from one OpenAPI document to another and
  # fails on them, unless the new `info.version` allows them (a new major
  # version, or a new minor one before 1.0). For CI against the main branch.
  class OpenAPIDiff < Command
    command "openapi:diff", "Report breaking changes between two OpenAPI documents: punch openapi:diff OLD NEW"

    struct Result
      include Report

      def initialize(@changes : Array(String), @allowed : Bool)
      end

      def to_text(io : IO) : Nil
        return io.puts("No breaking changes.") if @changes.empty?

        io.puts "Breaking changes, allowed by the new major version:"
        @changes.each { |change| io.puts "  #{change}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "breaking", @changes
          json.field "allowed", @allowed
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: punch openapi:diff OLD NEW") unless args.size == 2
      if missing = args.find { |path| !File.exists?(path) }
        return Failure.new("missing_file", "#{missing} does not exist.")
      end

      old, new = args.map { |path| JSON.parse(File.read(path)) }
      changes = Punch::OpenAPI::Diff.breaking(old, new)
      allowed = OpenAPIDiff.major_bump?(old.dig?("info", "version").try(&.as_s?), new.dig?("info", "version").try(&.as_s?))
      return Result.new(changes, allowed) if changes.empty? || allowed

      Failure.new("breaking_changes", "#{changes.size} breaking #{changes.size == 1 ? "change" : "changes"}; raise the major version in shard.yml if intended:\n  #{changes.join("\n  ")}")
    rescue ex : JSON::ParseException
      Failure.new("invalid_document", "not a JSON document: #{ex.message}")
    end

    # Whether *new* raises the major version of *old* (the minor one before
    # 1.0), by semantic versioning.
    def self.major_bump?(old : String?, new : String?) : Bool
      old_parts = old.try(&.split('.').map(&.to_i?)) || return false
      new_parts = new.try(&.split('.').map(&.to_i?)) || return false
      old_major, new_major = old_parts[0]? || 0, new_parts[0]? || 0
      return new_major > old_major if old_major > 0 || new_major > 0

      (new_parts[1]? || 0) > (old_parts[1]? || 0)
    end
  end
end
