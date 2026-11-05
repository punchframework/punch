require "./project"
require "../../docs_check"

module Punch::CLI::Commands
  # Checks Punch's own documentation (`Punch::DocsCheck`): every code block
  # in a guide quoted, failing, or illustrative; quotes current; links,
  # anchors, and `lib/punch/docs/` paths resolving; every page in the
  # index. With `--write`, refreshes the quotes first.
  class DocsCheck < Command
    command "docs:check", "Check Punch's documentation: guide code blocks quoted, failing, or illustrative, quotes current, links and anchors resolving, every page indexed; --write refreshes the quotes"

    struct Result
      include Report

      def initialize(@outcome : Punch::DocsCheck::Outcome)
      end

      def to_text(io : IO) : Nil
        @outcome.written.each { |path| io.puts "written   #{path}" }
        io.puts "#{@outcome.pages} pages, #{@outcome.quotes} quotes, #{@outcome.links} links: all current."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "pages", @outcome.pages
          json.field "quotes", @outcome.quotes
          json.field "links", @outcome.links
          json.field "written", @outcome.written
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      write = args.delete("--write")
      if extra = args.first?
        return Failure.usage("unexpected_argument", "'punch docs:check' takes --write, not '#{extra}'.")
      end
      return Failure.new("no_docs", "There is no #{Punch::DocsCheck::DIRECTORY}/ directory; docs:check runs in Punch's repository.") unless DocsCheck.applies?

      outcome = Punch::DocsCheck.run(!write.nil?)
      return Result.new(outcome) if outcome.problems.empty?

      Failure.new("docs_out_of_date", outcome.problems.join('\n', &.to_s),
        details: JSON.parse({problems: outcome.problems.map { |problem| {path: problem.path, line: problem.line, message: problem.message} }}.to_json))
    end

    # Whether the tools run this: Punch's own repository.
    def self.applies? : Bool
      Dir.exists?(Punch::DocsCheck::DIRECTORY) && File.exists?("shard.yml") && YAML.parse(File.read("shard.yml"))["name"]?.try(&.as_s?) == "punch"
    end
  end
end
