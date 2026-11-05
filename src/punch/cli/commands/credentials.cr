require "file_utils"

module Punch::CLI::Commands
  # What the `creds:` commands share: the `--env` option, the files of an
  # environment, and writing them safely. The commands work on the files
  # in `config/credentials/` of the current directory, without the app's
  # credentials type; `creds:check`, in application binaries, checks
  # against it.
  module Creds
    NAME = /\A[a-z_][a-z0-9_]*\z/

    # The environment from `--env NAME` (removed from *args*), else
    # `PUNCH_ENV`, else `development`.
    def self.environment(args : Array(String), command : String) : String | Failure
      environment = if index = args.index("--env")
                      value = args[index + 1]?
                      return Failure.usage("missing_argument", "'punch #{command} --env' needs an environment name.") unless value

                      args.delete_at(index, 2)
                      value
                    else
                      ENV["PUNCH_ENV"]?.presence || "development"
                    end
      return environment if Punch::Credentials::ENVIRONMENT.matches?(environment)

      Failure.usage("invalid_environment", "'#{environment}' is not an environment name (lowercase letters, digits, and _).")
    end

    # The master key of *environment*, or why there is none.
    def self.key(environment : String) : Punch::Credentials::MasterKey | Failure
      case key = Punch::Credentials::MasterKey.resolve(environment)
      in Punch::Credentials::MasterKey then key
      in String                        then Failure.new("invalid_key", key)
      in Nil
        Failure.new("missing_key", "No key for #{environment}: set #{Punch::Credentials::MasterKey::VARIABLE} or add #{Punch::Credentials.key_file(environment)}. Run 'punch creds:init --env #{environment}' to start a new file.")
      end
    end

    # The decrypted text of *environment*'s file and its key.
    def self.read(environment : String) : {String, Punch::Credentials::MasterKey} | Failure
      file = Punch::Credentials.file(environment)
      return Failure.new("missing_file", "#{file} does not exist. Run 'punch creds:init --env #{environment}'.") unless File.exists?(file)

      key = key(environment)
      return key if key.is_a?(Failure)

      case text = Punch::Credentials::EncryptedFile.decrypt(File.read(file), key)
      in Punch::Credentials::EncryptedFile::Error then Failure.new("cannot_decrypt", text.message(file, key))
      in String                                   then {text, key}
      end
    end

    # The decrypted mapping of *environment*'s file and its key.
    def self.read_tree(environment : String) : {Hash(String, Punch::Credentials::Tree), Punch::Credentials::MasterKey} | Failure
      read = read(environment)
      return read if read.is_a?(Failure)

      text, key = read

      case tree = Punch::Credentials::YAMLTree.parse(text, Punch::Credentials.file(environment))
      in String                                 then Failure.new("invalid_yaml", tree)
      in Hash(String, Punch::Credentials::Tree) then {tree, key}
      end
    end

    # Writes *text*, encrypted, through a temporary file and a rename.
    def self.write(environment : String, text : String, key : Punch::Credentials::MasterKey) : Nil
      replace(Punch::Credentials.file(environment), Punch::Credentials::EncryptedFile.encrypt(text, key))
    end

    def self.write_key(path : String, key : Punch::Credentials::MasterKey) : Nil
      replace(path, key.to_text + "\n", 0o600)
    end

    def self.replace(path : String, content : String, mode : Int32 = 0o644) : Nil
      Dir.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Random::Secure.hex(4)}.tmp"
      File.open(temporary, "w", perm: File::Permissions.new(mode)) { |file| file.print(content) }
      File.rename(temporary, path)
    end

    # The path `stripe.secret_key` as its names, or a usage failure.
    def self.path(text : String?, command : String) : Array(String) | Failure
      return Failure.usage("missing_argument", "'punch #{command}' needs a credential path such as stripe.secret_key.") unless text

      names = text.split('.')
      return names if names.all? { |name| NAME.matches?(name) }

      Failure.usage("invalid_path", "'#{text}' is not a credential path: names of lowercase letters, digits, and _, joined by dots.")
    end

    # *tree* with every value replaced by `[REDACTED]`.
    def self.redact(tree : Punch::Credentials::Tree) : Punch::Credentials::Tree
      case tree
      in Hash(String, Punch::Credentials::Tree)
        tree.transform_values { |value| redact(value).as(Punch::Credentials::Tree) }
      in Array(Punch::Credentials::Tree)
        tree.map { |value| redact(value).as(Punch::Credentials::Tree) }
      in String
        Punch::Secret::REDACTED
      in Nil
        nil
      end
    end

    def self.tree_json(json : JSON::Builder, tree : Punch::Credentials::Tree) : Nil
      case tree
      in Hash(String, Punch::Credentials::Tree)
        json.object { tree.each { |key, value| json.field(key) { tree_json(json, value) } } }
      in Array(Punch::Credentials::Tree)
        json.array { tree.each { |value| tree_json(json, value) } }
      in String then json.string(tree)
      in Nil    then json.null
      end
    end

    # A report of files written, as text and JSON.
    struct Written
      include Report

      def initialize(@environment : String, @files : Array({String, String}), @notes : Array(String) = [] of String)
      end

      def to_text(io : IO) : Nil
        @files.each { |path, state| io.puts "#{state.ljust(9)} #{path}" }
        @notes.each { |note| io.puts note }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "environment", @environment
          json.field "files" do
            json.array { @files.each { |path, state| json.object { json.field "path", path; json.field "state", state } } }
          end
          json.field "notes", @notes
        end
      end
    end
  end

  # Starts the credentials of an environment: a new key file (never
  # committed; `.gitignore` gains a rule) and an empty encrypted file.
  class CredsInit < Command
    command "creds:init", "Create config/credentials/<env>.key and an empty <env>.yml.enc; --env NAME (default PUNCH_ENV or development)"

    GITIGNORE = "/config/credentials/*.key"

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:init")
      return environment if environment.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      file, key_file = Punch::Credentials.file(environment), Punch::Credentials.key_file(environment)
      return Failure.new("file_exists", "#{file} exists already; edit it with 'punch creds:edit --env #{environment}'.") if File.exists?(file)
      return Failure.new("file_exists", "#{key_file} exists already, without #{file}; remove it first if it is not needed.") if File.exists?(key_file)

      key = Punch::Credentials::MasterKey.generate(key_file)
      Creds.write_key(key_file, key)
      Creds.write(environment, "# Credentials for #{environment}. Edit with 'punch creds:edit --env #{environment}'.\n", key)
      files = [{key_file, "written"}, {file, "written"}]
      files << {".gitignore", "updated"} if ignore_keys
      Creds::Written.new(environment, files, ["Keep #{key_file} out of the repository; deployments set #{Punch::Credentials::MasterKey::VARIABLE} instead."])
    end

    # Adds the rule for key files to `.gitignore`; whether it changed.
    private def ignore_keys : Bool
      current = File.exists?(".gitignore") ? File.read(".gitignore") : ""
      return false if current.lines.any?(&.strip.==(GITIGNORE))

      File.write(".gitignore", current + (current.empty? || current.ends_with?('\n') ? "" : "\n") + GITIGNORE + "\n")
      true
    end
  end

  # Opens the decrypted file in `$VISUAL` or `$EDITOR` and encrypts the
  # result. The plaintext lives in a private temporary directory only while
  # the editor runs. Invalid YAML is not written.
  class CredsEdit < Command
    command "creds:edit", "Edit config/credentials/<env>.yml.enc in $EDITOR; --env NAME"

    def self.json? : Bool
      false
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:edit")
      return environment if environment.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      editor = ENV["VISUAL"]?.presence || ENV["EDITOR"]?.presence
      return Failure.new("no_editor", "Set EDITOR to edit credentials, or use 'punch creds:set'.") unless editor

      read = Creds.read(environment)
      return read if read.is_a?(Failure)

      text, key = read
      # Memory-backed and per user where there is one, so the plaintext
      # never reaches a disk.
      base = ENV["XDG_RUNTIME_DIR"]?.presence.try { |dir| Dir.exists?(dir) ? dir : nil } || (Dir.exists?("/dev/shm") ? "/dev/shm" : Dir.tempdir)
      directory = File.tempname("punch-creds", dir: base)
      Dir.mkdir(directory, 0o700)
      # A signal while the editor runs reaches it too; punch outlives it, so
      # the ensure below removes the plaintext.
      {Signal::INT, Signal::HUP, Signal::TERM, Signal::QUIT}.each(&.ignore)
      begin
        path = File.join(directory, "#{environment}.yml")
        File.open(path, "w", perm: File::Permissions.new(0o600)) { |file| file.print(text) }
        status = Process.run("#{editor} #{Process.quote(path)}", shell: true,
          input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        return Failure.new("editor_failed", "The editor exited with #{status.exit_code}; nothing was written.") unless status.success?

        edited = File.read(path)
        file = Punch::Credentials.file(environment)
        return Creds::Written.new(environment, [{file, "unchanged"}]) if edited == text
        if problem = Punch::Credentials::YAMLTree.parse(edited, file).as?(String)
          return Failure.new("invalid_yaml", "#{problem}; nothing was written.")
        end

        Creds.write(environment, edited, key)
        Creds::Written.new(environment, [{file, "written"}], ["Rebuild the app: the file is compiled in."])
      ensure
        FileUtils.rm_rf(directory)
        {Signal::INT, Signal::HUP, Signal::TERM, Signal::QUIT}.each(&.reset)
      end
    end
  end

  # Prints the decrypted file, every value redacted unless `--reveal`.
  class CredsShow < Command
    command "creds:show", "Show the keys of config/credentials/<env>.yml.enc, values redacted; --reveal shows them; --env NAME"

    struct Result
      include Report

      def initialize(@environment : String, @file : String, @key : String, @tree : Hash(String, Punch::Credentials::Tree))
      end

      def to_text(io : IO) : Nil
        io.puts "# #{@file}, opened with #{@key}"
        io.print Punch::Credentials::YAMLTree.dump(@tree).lchop("---\n") unless @tree.empty?
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "environment", @environment
          json.field "file", @file
          json.field "key", @key
          json.field("credentials") { Creds.tree_json(json, @tree) }
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:show")
      return environment if environment.is_a?(Failure)

      reveal = args.delete("--reveal")
      if failure = no_arguments(args)
        return failure
      end

      read = Creds.read_tree(environment)
      return read if read.is_a?(Failure)

      tree, key = read
      tree = Creds.redact(tree).as(Hash(String, Punch::Credentials::Tree)) unless reveal
      Result.new(environment, Punch::Credentials.file(environment), key.origin, tree)
    end
  end

  # Sets one credential to the value read from stdin, so it stays out of
  # shell history and process lists. Comments in the file are not kept.
  class CredsSet < Command
    command "creds:set", "Set a credential (stripe.secret_key) to the value on stdin; --env NAME"

    property input : IO = STDIN

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:set")
      return environment if environment.is_a?(Failure)

      path = Creds.path(args.shift?, "creds:set")
      return path if path.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      read = Creds.read_tree(environment)
      return read if read.is_a?(Failure)

      tree, key = read
      value = input.gets_to_end.chomp
      return Failure.new("empty_value", "No value on stdin; pipe the value in, for example from a password manager.") if value.empty?

      node = tree
      path[0...-1].each_with_index do |name, index|
        child = node[name]?
        child = node[name] = {} of String => Punch::Credentials::Tree if child.nil?
        unless child.is_a?(Hash(String, Punch::Credentials::Tree))
          return Failure.new("not_a_group", "#{path[0..index].join('.')} holds a value, not a group of credentials.")
        end

        node = child
      end
      if node[path.last]?.is_a?(Hash) || node[path.last]?.is_a?(Array)
        return Failure.new("not_a_value", "#{path.join('.')} is a group; set one of its credentials instead.")
      end

      node[path.last] = value
      Creds.write(environment, Punch::Credentials::YAMLTree.dump(tree), key)
      Creds::Written.new(environment, [{Punch::Credentials.file(environment), "written"}], ["Set #{path.join('.')}. Rebuild the app: the file is compiled in."])
    end
  end

  # Removes one credential or group.
  class CredsUnset < Command
    command "creds:unset", "Remove a credential or group (stripe.secret_key); --env NAME"

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:unset")
      return environment if environment.is_a?(Failure)

      path = Creds.path(args.shift?, "creds:unset")
      return path if path.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      read = Creds.read_tree(environment)
      return read if read.is_a?(Failure)

      tree, key = read
      parent = path[0...-1].reduce(tree.as(Punch::Credentials::Tree)) { |node, name| node.as?(Hash(String, Punch::Credentials::Tree)).try(&.[name]?) }
      parent = parent.as?(Hash(String, Punch::Credentials::Tree))
      return Failure.new("not_found", "#{path.join('.')} is not in #{Punch::Credentials.file(environment)}.") unless parent && parent.has_key?(path.last)

      parent.delete(path.last)
      Creds.write(environment, Punch::Credentials::YAMLTree.dump(tree), key)
      Creds::Written.new(environment, [{Punch::Credentials.file(environment), "written"}], ["Removed #{path.join('.')}. Rebuild the app: the file is compiled in."])
    end
  end

  # Re-encrypts an environment's file under a new master key
  # (`creds:rekey`). The new key is written to the key file; the file is
  # replaced first, so an interrupted run leaves `<env>.key.new` to recover.
  class CredsRekey < Command
    command "creds:rekey", "Re-encrypt config/credentials/<env>.yml.enc under a new key and write the key file; --env NAME"

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:rekey")
      return environment if environment.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      read = Creds.read(environment)
      return read if read.is_a?(Failure)

      text, old = read
      key_file = Punch::Credentials.key_file(environment)
      key = Punch::Credentials::MasterKey.generate(key_file)
      Creds.write_key("#{key_file}.new", key)
      Creds.write(environment, text, key)
      File.rename("#{key_file}.new", key_file)
      notes = ["The old key no longer opens the file. Deployments that set #{Punch::Credentials::MasterKey::VARIABLE} need the new key from #{key_file}; rebuild and deploy together."]
      notes << "The old key came from #{old.origin}; unset it there." if old.origin == Punch::Credentials::MasterKey::VARIABLE
      Creds::Written.new(environment, [{Punch::Credentials.file(environment), "written"}, {key_file, "written"}], notes)
    end
  end

  # Checks the app's credentials as `serve` does at boot, against the
  # declared type, and shows where each value came from. In application
  # binaries only.
  class CredsCheck < Command
    command "creds:check", "Check the app's credentials for an environment as at boot and show where each came from; --env NAME"

    struct Result
      include Report

      def initialize(@source : Punch::Credentials::Source?)
      end

      def to_text(io : IO) : Nil
        unless source = @source
          io.puts "The app declares no credentials (Punch.credentials)."
          return
        end
        io.puts "Credentials for #{source.environment}: #{source.key_origin ? "#{source.file}, opened with #{source.key_origin}" : "environment only"}"
        width = source.entries.max_of?(&.path.size) || 0
        source.entries.each do |entry|
          value = entry.secret ? Punch::Secret::REDACTED : entry.value || "-"
          from = entry.origin.environment? ? entry.where : entry.origin.to_s.downcase
          io.puts "  #{entry.path.ljust(width)}  #{from.to_s.ljust(12)}  #{value}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "declared", !@source.nil?
          if source = @source
            json.field "environment", source.environment
            json.field "file", source.file
            json.field "key", source.key_origin
            json.field "credentials", source.entries
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "creds:check")
      return environment if environment.is_a?(Failure)
      if failure = no_arguments(args)
        return failure
      end

      source = Punch::Credentials.boot(environment)
      return Result.new(source) if source.nil? || source.problems.empty?

      CredsCheck.failure(source)
    end

    # The failure `invalid_credentials`, naming every problem.
    def self.failure(source : Punch::Credentials::Source) : Failure
      Failure.new("invalid_credentials", "The credentials for #{source.environment} have problems:\n  #{source.problems.join("\n  ")}",
        details: JSON.parse({problems: source.problems}.to_json))
    end
  end
end
