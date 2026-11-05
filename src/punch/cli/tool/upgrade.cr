require "digest/sha256"
require "file_utils"
require "./generate"

module Punch::CLI::Upgrade
  # One file of the template that differs between two Punch versions, what
  # that means for the app, and its part of the patch.
  record Change, path : String, status : Status, patch : String

  enum Status
    # The app has the previous rendering: the patch applies.
    Untouched
    # The app edited it, and the patch still applies.
    Applies
    # The app edited it where the template changed: merge by hand.
    Conflicts
    # The app removed it.
    Missing
    # New in the template.
    New
    # New in the template, but the app has a file there.
    Exists
    # Removed from the template; the app has the previous rendering.
    Removed
    # Removed from the template; the app edited it.
    RemovedEdited
    # A migration the app has applied changed in the template: never in
    # the patch, since applied migrations are checksummed.
    Migration

    def describe : String
      case self
      in Untouched     then "as the previous Punch wrote it: the patch applies"
      in Applies       then "edited in the app: the patch still applies"
      in Conflicts     then "edited in the app where the template changed: git apply --3way merges it"
      in Missing       then "removed from the app: not in the patch; decide whether it needs the change"
      in New           then "new in the template"
      in Exists        then "new in the template, but the app has a file there: not in the patch; merge by hand"
      in Removed       then "removed from the template"
      in RemovedEdited then "removed from the template, and edited in the app: not in the patch; decide whether to keep it"
      in Migration     then "an applied migration changed in the template: not in the patch; `punch check` (step punchtables) names the migration to write"
      end
    end

    # Whether the change is in the patch: `git apply` takes all of a patch
    # or none, so a file it cannot change stays out.
    def patched? : Bool
      untouched? || applies? || conflicts? || new? || removed?
    end
  end

  # Where built tools and exported sources are kept, per version or commit.
  def self.cache : String
    base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Path.home.to_s, ".cache")
    File.join(base, "punch", "upgrade")
  end

  # Punch's version in *lock*, a `shard.lock`.
  def self.locked_version(lock : String) : String?
    YAML.parse(lock)["shards"]?.try(&.["punch"]?).try(&.["version"]?).try(&.as_s?)
  rescue YAML::ParseException
  end

  # The Punch version the app had before *current*: in `shard.lock` at
  # `HEAD`, or before a later commit that changed it.
  def self.previous_version(root : String, current : String) : String | Failure
    commits = git(root, "log", "-50", "--format=%H", "--", "shard.lock")
    return Failure.new("no_history", "#{root} is not a git repository, or shard.lock was never committed: pass --from VERSION|REF|DIR.") unless commits

    (["HEAD"] + commits.lines.map { |commit| "#{commit}^" }).each do |revision|
      lock = git(root, "show", "#{revision}:shard.lock") || next
      version = locked_version(lock) || next
      return version if version != current
    end
    Failure.new("no_previous_version", "shard.lock names Punch #{current} in every commit that has it, so there is no previous Punch to compare with. " \
                                       "A path dependency keeps its version while Punch changes: pass --from REF (a commit or tag of the Punch checkout) or --from DIR.")
  end

  # The previous Punch's source directory and a label for it: *from* if
  # given (a directory, a version, or a ref), else *version*.
  def self.source(root : String, from : String?, version : String?) : {String, String, Bool} | Failure
    if from && File.exists?(File.join(from, "src", "cli", "main.cr"))
      return {File.expand_path(from), File.basename(File.expand_path(from)), false}
    end

    wanted = from || version || return Failure.usage("missing_argument", "Name the previous Punch with --from VERSION|REF|DIR.")
    return Failure.usage("invalid_ref", "#{wanted.inspect} is not a version, a ref, or a directory with Punch's source.") unless ref?(wanted)
    lock = File.join(root, "shard.lock")
    entry = File.exists?(lock) ? YAML.parse(File.read(lock))["shards"]?.try(&.["punch"]?) : nil
    if path = entry.try(&.["path"]?).try(&.as_s?)
      exported(File.expand_path(path, root), wanted)
    elsif url = entry.try(&.["git"]?).try(&.as_s?)
      cloned(url, wanted)
    else
      Failure.new("no_punch", "shard.lock has no punch entry: run shards install first.")
    end
  end

  # A version or a git ref as `git clone --branch` takes it: no path
  # tricks, no option.
  private def self.ref?(text : String) : Bool
    text.matches?(/\A[0-9A-Za-z_][0-9A-Za-z._\/-]*\z/) && !text.includes?("..")
  end

  private def self.version?(text : String) : Bool
    text.matches?(/\A\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.]+)?\z/)
  end

  # *wanted* (a version, by its tag, or a ref) of the Punch checkout at
  # *checkout*, exported into the cache by commit.
  private def self.exported(checkout : String, wanted : String) : {String, String, Bool} | Failure
    revision = version?(wanted) ? "v#{wanted}" : wanted
    commit = git(checkout, "rev-parse", "--verify", "--quiet", "#{revision}^{commit}").try(&.strip)
    unless commit
      hint = version?(wanted) ? "Punch's checkout at #{checkout} has no tag #{revision}" : "#{wanted} is no commit or tag of Punch's checkout at #{checkout}"
      return Failure.new("no_source", "#{hint}: pass --from REF (a commit or tag there) or --from DIR.")
    end
    directory = File.join(cache, commit, "src")
    return {directory, wanted, true} if File.exists?(File.join(directory, "src", "cli", "main.cr"))

    # Punch may be a directory of a larger repository; `git archive` keeps
    # only the current directory's part of a tree, so it runs at the top.
    prefix = git(checkout, "rev-parse", "--show-prefix").try(&.strip) || ""
    top = git(checkout, "rev-parse", "--show-toplevel").try(&.strip) || checkout
    Dir.mkdir_p(directory)
    tree = prefix.empty? ? commit : "#{commit}:#{prefix.rchop('/')}"
    error = IO::Memory.new
    archive = Process.run("sh", ["-c", %(set -o pipefail 2>/dev/null; git -C "$1" archive --format=tar "$2" | tar -x -C "$3"), "sh", top, tree, directory],
      output: Process::Redirect::Close, error: error)
    unless archive.success? && File.exists?(File.join(directory, "src", "cli", "main.cr"))
      FileUtils.rm_rf(directory)
      return Failure.new("no_source", "Exporting #{wanted} from #{checkout} failed: #{error.to_s.strip}")
    end
    {directory, wanted, true}
  end

  # Tag `v<version>` of the repository at *url*, cloned into the cache.
  private def self.cloned(url : String, wanted : String) : {String, String, Bool} | Failure
    tag = version?(wanted) ? "v#{wanted}" : wanted
    # Named by a hash, so no version text decides where the clone goes
    # (or what is deleted when it fails).
    directory = File.join(cache, "clone-#{Digest::SHA256.hexdigest("#{url}\n#{wanted}")[0, 16]}", "src")
    return {directory, wanted, true} if File.exists?(File.join(directory, "src", "cli", "main.cr"))

    Dir.mkdir_p(File.dirname(directory))
    error = IO::Memory.new
    unless Process.run("git", ["clone", "--quiet", "--depth", "1", "--branch", tag, url, directory], output: Process::Redirect::Close, error: error).success?
      FileUtils.rm_rf(directory)
      return Failure.new("no_source", "Cloning #{tag} of #{url} failed (the network is needed once per version): #{error.to_s.strip}")
    end
    {directory, wanted, true}
  end

  # The previous Punch's `punch`, built from *source*: once per cached
  # source, every time for a directory.
  def self.tool(source : String, cached : Bool) : String | Failure
    binary = cached ? File.join(File.dirname(source), "punch") : File.join(cache, "dir-#{Digest::SHA256.hexdigest(source)[0, 16]}", "punch")
    return binary if cached && File::Info.executable?(binary)

    Dir.mkdir_p(File.dirname(binary))
    output = IO::Memory.new
    unless Dir.exists?(File.join(source, "lib"))
      status = Process.run("shards", ["install", "--skip-postinstall", "--skip-executables"], chdir: source, output: output, error: output)
      return Failure.new("build_failed", "shards install for the previous Punch in #{source} failed:\n#{output.to_s.strip}") unless status.success?
    end
    status = Process.run("crystal", ["build", "src/cli/main.cr", "-o", binary], chdir: source, output: output, error: output)
    return Failure.new("build_failed", "Building the previous Punch's tool in #{source} failed:\n#{output.to_s.strip}") unless status.success?

    binary
  rescue ex : File::NotFoundError
    Failure.new("build_failed", "Building the previous Punch's tool needs crystal and shards on the PATH: #{ex.message}")
  end

  # The app's template as *tool* renders it (`punch template:render`).
  def self.render(tool : String, root : String, label : String) : Hash(String, String) | Failure
    directory = File.tempname("punch-upgrade")
    output = IO::Memory.new
    status = Process.run(tool, ["template:render", directory, "--json"], chdir: root, output: output, error: output,
      env: {Handshake::GUARD => "1", "PUNCH_ENV" => nil})
    unless status.success?
      if output.to_s.includes?("unknown_command")
        return Failure.new("no_template_render", "Punch #{label} has no `punch template:render`, so its template cannot be rendered for this app; " \
                                                 "upgrade:diff compares only from a Punch that has it.")
      end
      return Failure.new("render_failed", "Rendering the template with Punch #{label} failed:\n#{output.to_s.strip}")
    end
    files(directory)
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  # Every file under *directory*, by its relative path.
  def self.files(directory : String) : Hash(String, String)
    Dir.glob("#{directory}/**/*", match: File::MatchOptions::DotFiles).select { |path| File.file?(path) }.to_h do |path|
      {::Path[path].relative_to(directory).to_s, File.read(path)}
    end
  end

  # Every file that differs between *before* and *after*, compared with
  # the app in *root*.
  def self.compare(root : String, before : Hash(String, String), after : Hash(String, String)) : Array(Change)
    (before.keys | after.keys).sort.compact_map do |path|
      old, new = before[path]?, after[path]?
      next if old == new
      current = read(root, path)
      if old && new
        changed(root, path, old, new, current)
      elsif new
        added(root, path, new)
      elsif old && current
        Change.new(path, current == old ? Status::Removed : Status::RemovedEdited, Generate.diff(path, old, nil, root))
      end
    end
  end

  private def self.changed(root : String, path : String, old : String, new : String, current : String?) : Change
    return Change.new(path, Status::Migration, "") if path.starts_with?("db/migrations/")

    patch = Generate.diff(path, old, new, root)
    status = if current.nil?
               Status::Missing
             elsif current == old
               Status::Untouched
             else
               applies?(root, patch) ? Status::Applies : Status::Conflicts
             end
    Change.new(path, status, patch)
  end

  private def self.added(root : String, path : String, new : String) : Change
    target = migration_path(root, path)
    status = target.nil? || File.exists?(File.join(root, target)) ? Status::Exists : Status::New
    target ||= path
    Change.new(target, status, Generate.diff(target, nil, new, root))
  end

  # Where a migration new in the template goes: renamed to now, after the
  # app's own; `nil` when the app has one of that name.
  private def self.migration_path(root : String, path : String) : String?
    name = path.match(%r{\Adb/migrations/\d+_(.+)\.sql\z}).try(&.[1]) || return path
    return if Dir.glob(File.join(root, "db/migrations/*_#{name}.sql")).present?

    "db/migrations/#{Punch::Migrations.file_name(name)}"
  end

  private def self.read(root : String, path : String) : String?
    file = File.join(root, path)
    File.file?(file) ? File.read(file) : nil
  end

  # Whether *patch* applies to the app in *root* (`git apply --check`).
  private def self.applies?(root : String, patch : String) : Bool
    file = File.tempname("punch-upgrade", ".patch")
    File.write(file, patch)
    Process.run("git", ["apply", "--check", file], chdir: root, output: Process::Redirect::Close, error: Process::Redirect::Close).success?
  rescue File::NotFoundError
    false
  ensure
    File.delete?(file) if file
  end

  # The output of `git -C dir *args`, `nil` when it fails.
  private def self.git(dir : String, *args : String) : String?
    output = IO::Memory.new
    status = Process.run("git", ["-C", dir] + args.to_a, output: output, error: Process::Redirect::Close)
    status.success? ? output.to_s : nil
  rescue File::NotFoundError
  end
end

module Punch::CLI::Commands
  # Renders this app's template, as this Punch writes it for the app's
  # parts (`CLI::New::Detect`), into an empty directory; nothing else.
  # The previous Punch's tool answers it for `punch upgrade:diff`, so its
  # arguments and output stay as they are.
  class TemplateRender < Command
    command "template:render", "Render this app's template, as this Punch writes it for the app's parts, into an empty DIR: punch template:render DIR"

    struct Result
      include Report

      def initialize(@directory : String, @files : Array(String))
      end

      def to_text(io : IO) : Nil
        io.puts "Rendered #{@files.size} files into #{@directory}"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "directory", @directory
          json.field "files", @files
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: punch template:render DIR") unless args.size == 1

      directory = args.first
      if Dir.exists?(directory) && !Dir.empty?(directory)
        return Failure.new("directory_not_empty", "#{directory} is not empty; template:render writes only into a new or empty directory.")
      end

      app = CLI::New::Detect.app(".")
      return Failure.new("not_an_app", app) if app.is_a?(String)

      files = CLI::Generate.rendered(app)
      files.each do |path, content|
        target = File.join(directory, path)
        Dir.mkdir_p(File.dirname(target))
        File.write(target, content)
      end
      Result.new(directory, files.keys.sort!)
    end
  end

  # The template's change between the app's previous Punch and this one:
  # both rendered for the app's parts, the difference saved as a patch, and
  # each changed file's status. The app owns its code, so nothing in it is
  # changed.
  class UpgradeDiff < Command
    command "upgrade:diff", "Show how the app template changed since the app's previous Punch: punch upgrade:diff [--from VERSION|REF|DIR]"

    DIRECTORY = "tmp/upgrade"

    struct Result
      include Report

      def initialize(@from : String, @to : String, @changes : Array(CLI::Upgrade::Change), @patch : String?)
      end

      def to_text(io : IO) : Nil
        if @changes.empty?
          io.puts "The template is the same in Punch #{@from} and #{@to} for this app: nothing to apply."
          return
        end
        io.puts "The template changed from Punch #{@from} to #{@to} in #{@changes.size} #{@changes.size == 1 ? "file" : "files"}:"
        width = @changes.max_of(&.path.size)
        @changes.each { |change| io.puts "  #{change.path.ljust(width)}  #{change.status.describe}" }
        if patch = @patch
          io.puts
          io.puts "The change is in #{patch}. Apply it, look at the result, then run punch check:"
          if @changes.any?(&.status.conflicts?)
            io.puts "  git apply --3way #{patch}   # leaves conflict markers where an edited file conflicts"
          else
            io.puts "  git apply #{patch}"
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "from", @from
          json.field "to", @to
          json.field "patch", @patch
          json.field "changes" do
            json.array do
              @changes.each do |change|
                json.object do
                  json.field "path", change.path
                  json.field "status", change.status.to_s.underscore
                  json.field "patched", change.status.patched?
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      from = AuthCommand.option(args, "--from")
      return from if from.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch upgrade:diff' takes --from VERSION|REF|DIR, not '#{args.first}'.") unless args.empty?

      app = CLI::New::Detect.app(".")
      return Failure.new("not_an_app", app) if app.is_a?(String)

      version = nil
      unless from
        version = CLI::Upgrade.previous_version(".", Punch::VERSION)
        return version if version.is_a?(Failure)
      end
      source = CLI::Upgrade.source(".", from, version)
      return source if source.is_a?(Failure)

      directory, label, cached = source
      tool = CLI::Upgrade.tool(directory, cached)
      return tool if tool.is_a?(Failure)

      before = CLI::Upgrade.render(tool, ".", label)
      return before if before.is_a?(Failure)

      changes = CLI::Upgrade.compare(".", before, CLI::Generate.rendered(app))
      Result.new(label, Punch::VERSION, changes, write_patch(label, changes))
    end

    # The patch of every change it holds, `nil` when there is none.
    private def write_patch(from : String, changes : Array(CLI::Upgrade::Change)) : String?
      text = changes.select(&.status.patched?).join(&.patch)
      return if text.empty?

      path = File.join(DIRECTORY, "#{from.gsub(/[^A-Za-z0-9._-]+/, "_")}-#{Punch::VERSION}.patch")
      Dir.mkdir_p(DIRECTORY)
      File.write(path, text)
      path
    end
  end
end
