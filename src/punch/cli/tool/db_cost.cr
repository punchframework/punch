require "../../migrations/cost"

module Punch::CLI::Commands
  # Sorts every migration statement into instant, scan, or rebuild, from the
  # migrations in `db/migrations/`. With `--check`, fails on a rebuild the
  # file does not acknowledge with `-- rebuild: <table>`. With `--base REF`,
  # only migrations that REF does not have are checked: the shipped ones ran
  # already and cannot be edited.
  class DbCost < Command
    command "db:cost", "Show what each migration statement costs on a large table: instant, scan, or rebuild; --check fails on an unacknowledged rebuild, --base REF checks only migrations REF does not have"

    struct Result
      include Report

      def initialize(@reports : Array(Punch::Migrations::Costs::Report), @new : Set(Int64), @base : String?)
      end

      def to_text(io : IO) : Nil
        io << @reports.size << (@reports.size == 1 ? " migration: " : " migrations: ")
        io << Punch::Migrations::Cost.values.join(", ") { |cost| "#{@reports.count(&.cost.==(cost))} #{cost.to_s.downcase}" }
        io << "; " << @new.size << " new" << (@base ? " since #{@base}" : "") unless @base.nil? && @new.size == @reports.size
        io << '\n'
        @reports.each do |report|
          io << report.cost.to_s.downcase.ljust(8) << ' ' << report.migration.file_name
          io << "  rebuilds " << report.rebuilds.join(", ") unless report.rebuilds.empty?
          io << (report.problems.empty? ? " (acknowledged)" : " (not acknowledged)") unless report.rebuilds.empty?
          io << "  new" if @base && @new.includes?(report.migration.version)
          io << '\n'
          report.statements.each do |statement|
            next if statement.cost.instant?
            io << "  " << statement.cost.to_s.downcase.ljust(8) << statement.line.to_s.rjust(4) << "  " << statement.sql << "\n"
            io << "                " << statement.reason << '\n'
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "base", @base
          json.field "migrations" do
            json.array do
              @reports.each do |report|
                json.object do
                  report.fields(json)
                  json.field "new", @new.includes?(report.migration.version)
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      check = !!args.delete("--check")
      base = nil
      if index = args.index("--base")
        base = args[index + 1]? || return Failure.usage("missing_argument", "--base needs a Git revision, such as origin/main.")
        args.delete_at(index, 2)
      end
      if failure = no_arguments(args)
        return failure
      end

      migrations = Punch::Migrations.from_directory
      shipped = base ? DbCost.shipped(base) : Set(String).new
      return shipped if shipped.is_a?(Failure)

      reports = Punch::Migrations::Costs.classify(migrations)
      new = reports.reject { |report| shipped.includes?(report.migration.file_name) }.map(&.migration.version).to_set
      result = Result.new(reports, new, base)
      return result unless check

      problems = reports.select { |report| new.includes?(report.migration.version) }.flat_map(&.problems)
      return result if problems.empty?

      Failure.new("unacknowledged_rebuild", problems.join("\n"), details: JSON.parse(result.to_json))
    rescue ex : Punch::Migrations::Error | Punch::Database::Error
      MigrationCommand.failure(ex)
    end

    # The migration files *base* has.
    def self.shipped(base : String) : Set(String) | Failure
      output = IO::Memory.new
      status = Process.run("git", ["ls-tree", "--name-only", base, "--", "#{Punch::Migrations::DIRECTORY}/"], output: output, error: Process::Redirect::Close)
      return Failure.usage("unknown_revision", "git does not know the revision '#{base}'.") unless status.success?

      output.to_s.lines.map { |path| File.basename(path) }.to_set
    rescue File::NotFoundError
      Failure.new("no_git", "--base needs git, which is not installed.")
    end
  end
end
