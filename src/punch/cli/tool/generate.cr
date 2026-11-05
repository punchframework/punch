require "file_utils"
require "./new"

module Punch::CLI::Generate
  # How a generated outline starts until the developer writes it:
  # `Punch/NamespaceFile` reports the line, so `punch check` fails until the
  # namespace's meaning is written down.
  PLACEHOLDER = "# punch generate:"

  # The directories of a kind, and the file names of a kind: no namespace
  # can take one of these names (`docs/structure.md`).
  RESERVED = RequiresGen::DIRECTORIES.keys + RequiresGen::FIXED.keys.map(&.rchop(".cr")) + %w[setup requires translations app]

  # What a generator decided before anything is written: new files, files
  # it replaces because the app left them as the template wrote them, and
  # a patch for the ones the app has edited.
  class Plan
    getter writes = [] of New::Template::Output
    getter replaces = [] of New::Template::Output
    # Paths whose template change is in `patch`.
    getter edited = [] of String
    property patch = ""
    # Whether a migration is among the new files, so `db:migrate` runs.
    property? migration = false
    # Whether the steps include `db:generate`: a table is mapped, or
    # queries are new.
    property? queries = false
    # Whether the steps include the API document and the payload lock,
    # for new operations and jobs.
    property? operations = false
    # Whether the steps wait for the developer: a new table's columns
    # belong in its migration before anything applies it.
    property? held = false
    # What the developer does next, before `punch check`.
    getter todo = [] of String

    def files : Array(New::Template::Output)
      writes + replaces
    end
  end

  # `billing/plans` or `Billing::Plans` as directory names, or what is
  # wrong with it.
  def self.segments(path : String) : Array(String) | String
    names = path.includes?("::") ? path.lchop("::").split("::").map { |name| QueryGen.underscore(name) } : path.strip('/').lchop("app/").split('/')
    names.each do |name|
      return "a namespace path is directories of lowercase letters, digits, and _ (billing/plans), got '#{path}'" unless name.matches?(/\A[a-z][a-z0-9_]*\z/)
      return "#{name} is the name of a file kind or a kind directory (lib/punch/docs/structure.md); choose another" if RESERVED.includes?(name)
    end
    return "a namespace path names at least one directory, such as billing/plans" if names.empty?

    names
  end

  # `Billing::Plans` for `["billing", "plans"]`.
  def self.module_name(segments : Array(String)) : String
    segments.join("::") { |name| QueryGen.camelcase(name) }
  end

  # An outline with the placeholder.
  def self.outline(segments : Array(String)) : String
    name = module_name(segments)
    <<-CRYSTAL
      #{PLACEHOLDER} say here what #{name} means in this app, what it is
      # for, and how it relates to the other namespaces, in plain words
      # (lib/punch/docs/models.md). `punch check` reports this line until then.
      module #{name}
      end

      CRYSTAL
  end

  # A namespace without tables (`accounts/sign_up`): its outline, and the
  # outlines of parents that have none.
  def self.namespace(root : String, path : String) : Plan | Failure
    segments = segments(path)
    return Failure.usage("invalid_path", segments) if segments.is_a?(String)

    plan = Plan.new
    if problem = namespace_files(root, segments, plan)
      return problem
    end

    directory = "app/#{segments.join('/')}"
    plan.todo << "Write the outline in #{directory}.cr."
    plan.todo << "Add the namespace's operations under #{directory}/operations/ and pages under #{directory}/pages/ (lib/punch/docs/structure.md)."
    plan
  end

  private def self.namespace_files(root : String, segments : Array(String), plan : Plan) : Failure?
    directory = "app/#{segments.join('/')}"
    if Dir.exists?(File.join(root, directory)) || File.exists?(File.join(root, "#{directory}.cr"))
      return Failure.new("exists", "#{module_name(segments)} exists already (#{directory}.cr or #{directory}/).")
    end

    (1..segments.size).each do |size|
      outline = "app/#{segments[0, size].join('/')}.cr"
      next if size < segments.size && File.exists?(File.join(root, outline))
      plan.writes << New::Template::Output.new(outline, outline(segments[0, size]))
    end
    nil
  end

  # An entity: the namespace's outline, `types.cr` with its ID, `columns.cr`
  # mapping its table, and `queries.sql`; a migration creating the table
  # when the schema has none.
  def self.entity(root : String, path : String, table : String?) : Plan | Failure
    segments = segments(path)
    return Failure.usage("invalid_path", segments) if segments.is_a?(String)

    table ||= segments.last
    return Failure.usage("invalid_table", "a table name is lowercase letters, digits, and _, got '#{table}'") unless table.matches?(/\A[a-z][a-z0-9_]*\z/)
    return Failure.usage("invalid_table", "#{table} is Punch's: tables named punch_* are Punch's own") if table.starts_with?("punch_")

    plan = Plan.new
    if problem = namespace_files(root, segments, plan)
      return problem
    end

    plan.queries = true
    name = module_name(segments)
    directory = "app/#{segments.join('/')}"
    found = table_columns(root, table)
    return found if found.is_a?(Failure)

    if found
      mapped, unmapped = found
    else
      migration = "db/migrations/#{Punch::Migrations.file_name("create_#{table}")}"
      plan.writes << New::Template::Output.new(migration, <<-SQL)
        -- The table of #{name}, mapped in #{directory}/columns.cr. Add its
        -- columns here before it is applied anywhere; once it is, change it
        -- only in a new migration (lib/punch/docs/migrations.md).
        CREATE TABLE #{table} (
          id INTEGER PRIMARY KEY AUTOINCREMENT
        ) STRICT;

        SQL
      plan.migration = true
      plan.held = true
      mapped, unmapped = [{"id", "ID"}], [] of {String, String}
      plan.todo << "Add the table's columns in #{migration}; then map them in #{directory}/columns.cr."
    end
    plan.writes << New::Template::Output.new("#{directory}/types.cr", <<-CRYSTAL)
      # The ID of a row of #{name}, the type of the columns that hold
      # one (lib/punch/docs/core-types.md).

      module #{name}
        struct ID < Punch::TypedID
        end
      end

      CRYSTAL
    plan.writes << New::Template::Output.new("#{directory}/columns.cr", columns(table, name, mapped, unmapped))
    plan.writes << New::Template::Output.new("#{directory}/queries.sql", <<-SQL)
      -- Named queries of #{name} (lib/punch/docs/queries.md): each starts with
      -- `-- name: Name :one|:many|:page|:exec|:execrows`, and `punch
      -- db:generate` turns it into a typed method. #{name}::Table already
      -- finds, inserts, updates, and deletes one row.

      SQL
    plan.todo.unshift("Write the outline in #{directory}.cr.")
    plan.todo << "Map the columns listed in #{directory}/columns.cr to their domain types." unless unmapped.empty?
    plan.todo << "Add operations under #{directory}/operations/ and pages under #{directory}/pages/, with specs in spec/#{segments.join('/')}/."
    plan
  end

  # `columns.cr` for *table*: a line per mapped column, a comment listing
  # the others with their stored types.
  private def self.columns(table : String, name : String, mapped : Array({String, String}), unmapped : Array({String, String})) : String
    String.build do |io|
      io << "# Which columns of these tables hold which domain types (lib/punch/docs/queries.md).\n"
      io << "# Read by `punch db:generate` and required by the app.\n"
      unless unmapped.empty?
        io << "#\n# Read as their stored types until mapped here:\n"
        unmapped.each { |column, type| io << "#   " << column << ": " << type << "\n" }
      end
      io << "\nPunch.table " << table.inspect << ", " << name
      mapped.each do |column, type|
        io << ",\n  " << column << ": " << (type == "ID" ? "#{name}::ID" : type)
      end
      io << "\n"
    end
  end

  # The columns of *table* in `db/schema.sql`, mapped and not, or `nil`
  # when the schema has no such table. "ID" stands for the entity's own.
  private def self.table_columns(root : String, table : String) : {Array({String, String}), Array({String, String})} | Failure?
    schema_path = File.join(root, Punch::Migrations::SCHEMA)
    return unless File.exists?(schema_path)

    database = Punch::Database.memory(name: "generate-entity", config: Punch::Database::Config.new(readers: 1))
    begin
      Punch::Migrations::Schema.load(database, File.read(schema_path), schema_path)
      schema = QueryGen::Schema.new(database)
      modules = {} of String => String
      QueryGen.mapping_files(root).each do |file|
        QueryGen::Mapping.apply(schema, File.read(File.join(root, file)), file, modules)
      end
      found = schema.table(table) || return
      if found.mod
        return Failure.new("mapped", "#{table} is mapped already, in #{found.mapped_in}: it has its entity.")
      end
      return Failure.new("not_strict", "#{table} is not STRICT: Punch maps only STRICT tables (lib/punch/docs/queries.md). Rebuild it as STRICT in a migration first.") unless found.strict?

      references = database.read do |reader|
        reader.query_all(%(SELECT "from", "table", "to" FROM pragma_foreign_key_list(?)), table) { |row| {row.read(String), row.read(String), row.read(String?)} }
      end
      mapped = [] of {String, String}
      unmapped = [] of {String, String}
      rowid = found.rowid
      found.columns.each do |column|
        stored = column.type.try(&.stored) || "any"
        if column == rowid
          mapped << {column.name, "ID"}
        elsif type = referenced_id(schema, references, column.name)
          mapped << {column.name, type}
        elsif stored == "String" && column.name.ends_with?("_at")
          mapped << {column.name, "Time"}
        else
          unmapped << {column.name, stored}
        end
      end
      {mapped, unmapped}
    rescue ex : Punch::Migrations::Error
      Failure.new("schema", "#{schema_path} does not load: #{ex.message}")
    ensure
      database.close
    end
  end

  # The ID type of the mapped table *column* references by its rowid.
  private def self.referenced_id(schema : QueryGen::Schema, references : Array({String, String, String?}), column : String) : String?
    reference = references.find { |from, _, _| from == column } || return
    target = schema.table(reference[1]) || return
    rowid = target.rowid || return
    return if (to = reference[2]) && to != rowid.name

    rowid.type.try(&.domain)
  end

  # An optional part of the accounts slice added later: the template
  # rendered for the app without and with it.
  def self.part(root : String, part : String) : Plan | Failure
    unless New::Template::PARTS.has_key?(part)
      return Failure.usage("unknown_part", "'#{part}' is not a part of the accounts slice. Parts: #{New::Template::PARTS.map { |name, what| "#{name} (#{what})" }.join(", ")}.")
    end

    app = New::Detect.app(root)
    return Failure.new("not_an_app", app) if app.is_a?(String)
    return Failure.new("exists", "The app has #{part} already (app/accounts/#{part}/).") if app.part?(part)

    before = rendered(app)
    after = rendered(app.with_part(part))
    plan = Plan.new
    plan.queries = true
    plan.operations = true
    existing = [] of String
    after.each do |path, content|
      if base = before[path]?
        changed(root, path, base, content, plan)
      else
        added(root, path, content, plan, existing)
      end
    end
    unless existing.empty?
      return Failure.new("exists", "Adding #{part} writes files the app has already: #{existing.join(", ")}. Move them aside, or add the part by hand.")
    end

    unless plan.edited.empty?
      plan.patch = patch(plan.edited, before, after, root)
    end
    plan
  end

  # A file the part changes: replaced when the app left it as *base*,
  # else edited.
  private def self.changed(root : String, path : String, base : String, content : String, plan : Plan) : Nil
    return if base == content

    current = File.join(root, path)
    if File.exists?(current) && File.read(current) == base
      plan.replaces << New::Template::Output.new(path, content)
    else
      plan.edited << path
    end
  end

  # A file the part adds; a migration gets the current time. Collects
  # into *existing* what is there already.
  private def self.added(root : String, path : String, content : String, plan : Plan, existing : Array(String)) : Nil
    if migration = path.match(%r{\Adb/migrations/\d+_(.+)\.sql\z}).try(&.[1])
      if taken = Dir.glob(File.join(root, "db/migrations/*_#{migration}.sql")).first?
        existing << ::Path[taken].relative_to(root).to_s
        return
      end
      path = "db/migrations/#{Punch::Migrations.file_name(migration)}"
      plan.migration = true
    end
    existing << path if File.exists?(File.join(root, path))
    plan.writes << New::Template::Output.new(path, content)
  end

  # Every file of *app*'s template, as `punch new` leaves it: Crystal
  # formatted (`punch new` runs the formatter after rendering).
  def self.rendered(app : New::App) : Hash(String, String)
    New::Template.render(app).to_h do |file|
      content = file.content
      if file.path.ends_with?(".cr")
        content = begin
          Crystal.format(content, filename: file.path)
        rescue Crystal::SyntaxException
          content
        end
      end
      {file.path, content}
    end
  end

  # A unified diff of *paths* from *before* to *after*, for `git apply`;
  # with *repository*, for `git apply --3way` too (`diff`).
  def self.patch(paths : Array(String), before : Hash(String, String), after : Hash(String, String), repository : String? = nil) : String
    paths.sort.join { |path| diff(path, before[path]?, after[path]?, repository) }
  end

  # A unified diff of one file with git's headers, `nil` for a side that
  # does not exist (a new or a deleted file), for `git apply`. With
  # *repository* (a git working tree), both sides are written to its
  # object store and named in the `index` line, so `git apply --3way` can
  # merge a file the app has edited; the app's files stay as they are.
  def self.diff(path : String, old : String?, new : String?, repository : String? = nil) : String
    body = unified(path, old, new)
    return "" if body.empty?

    mode = path.ends_with?(".sh") ? "100755" : "100644"
    String.build do |io|
      io << "diff --git a/" << path << " b/" << path << "\n"
      io << "new file mode " << mode << "\n" unless old
      io << "deleted file mode " << mode << "\n" unless new
      if repository && (from = blob(repository, old)) && (to = blob(repository, new))
        io << "index " << from << ".." << to
        io << " " << mode if old && new
        io << "\n"
      end
      io << body
    end
  end

  # What `diff -u` says from *old* to *new*, with `/dev/null` for a side
  # that does not exist.
  private def self.unified(path : String, old : String?, new : String?) : String
    work = File.tempname("punch-diff")
    Dir.mkdir(work, 0o700)
    File.write(File.join(work, "a"), old || "")
    File.write(File.join(work, "b"), new || "")
    output = IO::Memory.new
    Process.run("diff", ["-u", "--label", old ? "a/#{path}" : "/dev/null", "--label", new ? "b/#{path}" : "/dev/null",
                         File.join(work, "a"), File.join(work, "b")], output: output)
    output.to_s
  ensure
    FileUtils.rm_rf(work) if work
  end

  # *content* written to the object store of the git repository at
  # *repository*: its ID, zeros for none, `nil` outside a repository.
  private def self.blob(repository : String, content : String?) : String?
    return "0" * 40 unless content

    output = IO::Memory.new
    status = Process.run("git", ["hash-object", "-w", "--stdin"], chdir: repository, input: IO::Memory.new(content), output: output, error: Process::Redirect::Close)
    status.success? ? output.to_s.strip : nil
  rescue File::NotFoundError
  end

  # Writes *plan*'s files into *root*, and nowhere else: a path that
  # leaves it, or goes through a symbolic link, is refused.
  def self.write(root : String, plan : Plan) : Nil
    plan.files.each do |file|
      path = File.join(root, file.path)
      confined!(root, file.path)
      Dir.mkdir_p(File.dirname(path))
      File.write(path, file.content)
    end
  end

  # Raises unless *relative* stays inside *root* without a symbolic link
  # on the way.
  def self.confined!(root : String, relative : String) : Nil
    parts = Path.posix(relative).parts
    if relative.starts_with?('/') || parts.includes?("..")
      raise ArgumentError.new("refusing to write #{relative}: outside the app")
    end
    current = root
    parts.each do |part|
      current = File.join(current, part)
      info = File.info?(current, follow_symlinks: false) || break
      raise ArgumentError.new("refusing to write #{relative}: #{current} is a symbolic link") if info.symlink?
    end
  end
end

module Punch::CLI::Commands
  # Adds to an app what follows from conventions: an entity's or a
  # namespace's files, or an optional part of the accounts slice from the
  # template `punch new` renders. Never an operation or a page: that is the
  # app's content.
  class Generate < Command
    command "generate", "Add to an app: punch generate entity PATH [--table NAME] | namespace PATH | accounts " \
                        "magic_links|organizations|second_factor|tokens [--skip-steps]"

    PATCHES = "tmp/generate"

    struct Result
      include Report

      def initialize(@written : Array(String), @replaced : Array(String), @edited : Array(String), @patch : String?,
                     @steps : Array(CLI::New::Step), @next : Array(String))
      end

      def to_text(io : IO) : Nil
        @written.each { |path| io.puts "  created  #{path}" }
        @replaced.each { |path| io.puts "  updated  #{path}" }
        if patch = @patch
          io.puts
          io.puts "The template also changes files this app has edited; their change is in #{patch}:"
          @edited.each { |path| io.puts "  #{path}" }
        end
        @steps.each { |step| io.puts "  #{step.status.to_s.ljust(7)} #{step.name}" }
        unless @next.empty?
          io.puts
          io.puts "Next:"
          @next.each { |line| io.puts "  #{line}" }
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "created", @written
          json.field "updated", @replaced
          json.field "edited", @edited
          json.field "patch", @patch
          json.field "steps", @steps
          json.field "next", @next
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      parsed = parse(args)
      return parsed if parsed.is_a?(Failure)

      kind, target, table, skip = parsed
      plan = plan(kind, target, table)
      return plan if plan.is_a?(Failure)

      CLI::Generate.write(".", plan)
      patch = write_patch(plan, target)
      steps, remaining = run_steps(plan, skip || plan.held? || !patch.nil?)
      following = plan.todo.dup
      following << "git apply #{patch}   # or merge it by hand where it does not apply" if patch
      following.concat(remaining)
      following << "punch check"
      result = Result.new(plan.writes.map(&.path), plan.replaces.map(&.path), plan.edited, patch, steps, following)
      if failed = steps.find(&.status.==(:failed))
        return Failure.new("step_failed", "#{failed.name} failed; the files are written. Fix it, then run:\n  #{following.join("\n  ")}\n\n#{failed.detail.rstrip}",
          details: JSON.parse(result.to_json))
      end
      result
    end

    # The generator, its target, the table, and whether to skip the steps.
    private def parse(args : Array(String)) : {String, String, String?, Bool} | Failure
      args = args.dup
      skip = !args.delete("--skip-steps").nil?
      table = AuthCommand.option(args, "--table")
      return table if table.is_a?(Failure)
      if unknown = args.find(&.starts_with?("-"))
        return Failure.usage("unexpected_argument", "'punch generate' does not know #{unknown}. #{self.class.summary}")
      end

      kind, target = args[0]?, args[1]?
      return Failure.usage("missing_argument", "Usage: #{self.class.summary.split(": ", 2).last}") unless kind && target && args.size == 2
      return Failure.usage("unexpected_argument", "--table applies to entities.") if table && kind != "entity"

      {kind, target, table, skip}
    end

    private def plan(kind : String, target : String, table : String?) : CLI::Generate::Plan | Failure
      case kind
      when "entity"    then CLI::Generate.entity(".", target, table)
      when "namespace" then CLI::Generate.namespace(".", target)
      when "accounts"  then CLI::Generate.part(".", target)
      else                  Failure.usage("unknown_generator", "punch generate makes an entity, a namespace, or an accounts part, not '#{kind}'. #{self.class.summary}")
      end
    end

    # The patch for edited files, written under `tmp/generate/`: its path,
    # or `nil` when there is none.
    private def write_patch(plan : CLI::Generate::Plan, part : String) : String?
      return if plan.patch.empty?

      path = File.join(PATCHES, "accounts-#{part}.patch")
      Dir.mkdir_p(PATCHES)
      File.write(path, plan.patch)
      path
    end

    # The commands that bring the generated files' companions up to date;
    # run unless *skip*, else returned to be run.
    private def run_steps(plan : CLI::Generate::Plan, skip : Bool) : {Array(CLI::New::Step), Array(String)}
      planned = [] of {String, Array(String), String?}
      planned << {"db:migrate", ["punch", "db:migrate"], nil} if plan.migration?
      planned << {"db:generate", ["punch", "db:generate"], nil} if plan.queries?
      planned << {"i18n:generate", ["punch", "i18n:generate"], nil} if plan.operations?
      planned << {"requires:generate", ["punch", "requires:generate"], nil}
      if plan.operations?
        planned << {"openapi", ["punch", "openapi"], nil}
        planned << {"jobs:lock", ["punch", "jobs:lock"], nil}
      end
      return {[] of CLI::New::Step, planned.map { |(_, command, _)| command.join(' ') }} if skip

      CLI::New::Steps.run(".", planned)
    end
  end
end
