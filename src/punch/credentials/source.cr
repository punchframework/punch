module Punch::Credentials
  # Where a credentials type finds its values while it loads: the
  # environment first, then the decrypted file. It records what it found for
  # `creds:check` and every problem for the boot check. Values never appear
  # in a problem or in the record of a secret.
  class Source
    # Variables that a top-level credential must not read by accident.
    RESERVED = %w[PATH HOME USER SHELL PWD HOST HOSTNAME LANG TERM TMPDIR TZ EDITOR]

    enum Origin
      Environment
      File
      Default
      Absent
    end

    # One field as loaded: *where* names the variable or the place in the
    # file; *value* is `nil` for a secret.
    record Entry, path : String, origin : Origin, where : String?, secret : Bool, value : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "path", path
          json.field "origin", origin.to_s.underscore
          json.field "where", where
          json.field "secret", secret
          json.field "value", value
        end
      end
    end

    getter environment : String
    # The credentials file of the environment, as a path for messages.
    getter file : String
    # Where the master key came from, when the file was opened with one.
    getter key_origin : String?
    getter entries = [] of Entry
    getter problems = [] of String

    def initialize(@environment : String, @env : Proc(String, String?), @tree : Hash(String, Tree)?, @file : String,
                   @note : String? = nil, problems : Array(String) = [] of String, @key_origin : String? = nil)
      @problems.concat(problems)
    end

    # The source for *environment*, with *embedded* (the file's text as
    # compiled into the binary, or `nil`) decrypted by the environment's
    # master key.
    def self.open(environment : String, embedded : String?, env = ENV, directory : String = DIRECTORY,
                  declared : Bool = true) : Source
      lookup = ->(name : String) { env[name]?.presence }
      file = Credentials.file(environment, directory)
      unless embedded
        note = File.exists?(file) ? "#{file} exists but is not compiled in: #{declared ? "rebuild the app" : "declare its environment in Punch.credentials"}" : nil
        return new(environment, lookup, nil, file, note)
      end

      case key = MasterKey.resolve(environment, env, directory)
      in Nil
        new(environment, lookup, nil, file, "#{file} is compiled in, but there is no key: set #{MasterKey::VARIABLE} or add #{Credentials.key_file(environment, directory)}")
      in String
        new(environment, lookup, nil, file, problems: [key])
      in MasterKey
        case text = EncryptedFile.decrypt(embedded, key)
        in EncryptedFile::Error then new(environment, lookup, nil, file, problems: [text.message(file, key)])
        in String
          case tree = YAMLTree.parse(text, file)
          in String             then new(environment, lookup, nil, file, problems: [tree])
          in Hash(String, Tree) then new(environment, lookup, tree, file, key_origin: key.origin)
          end
        end
      end
    end

    # The text of the credential at *path* and where it came from.
    def lookup(path : Array(String)) : {String, Origin, String}?
      variable = Credentials.variable(path)
      if path.size == 1 && RESERVED.includes?(variable)
        @problems << "#{dotted(path)} would read the environment variable #{variable}; rename it or move it into a group"
      elsif value = @env.call(variable)
        return {value, Origin::Environment, variable}
      end

      case node = dig(path)
      in String then {node, Origin::File, "#{dotted(path)} in #{file}"}
      in Nil    then nil
      in Hash(String, Tree), Array(Tree)
        @problems << "#{dotted(path)} in #{file} must be a single value, not a #{node.is_a?(Hash) ? "mapping" : "list"}"
        nil
      end
    end

    # Reports keys of the mapping at *path* in the file that no field
    # declares, so a misspelt key does not silently leave a default.
    def check_keys(path : Array(String), names : Array(String)) : Nil
      case node = path.empty? ? @tree : dig(path)
      in Hash(String, Tree)
        node.each_key do |key|
          next if names.includes?(key)
          @problems << "#{dotted(path + [key])} in #{file} is not a declared credential"
        end
      in String, Array(Tree)
        @problems << "#{dotted(path)} in #{file} must be a mapping of #{names.join(", ")}"
      in Nil
      end
    end

    def found(path : Array(String), origin : Origin, where : String, secret : Bool, value : String) : Nil
      @entries << Entry.new(dotted(path), origin, where, secret, secret ? nil : value)
    end

    def defaulted(path : Array(String), secret : Bool, value : String) : Nil
      @entries << Entry.new(dotted(path), Origin::Default, nil, secret, secret ? nil : value)
    end

    def absent(path : Array(String), secret : Bool) : Nil
      @entries << Entry.new(dotted(path), Origin::Absent, nil, secret, nil)
    end

    def missing(path : Array(String)) : Nil
      message = "#{dotted(path)} is missing: set #{Credentials.variable(path)} or add it to #{file}"
      @problems << (@note ? "#{message} (#{@note})" : message)
    end

    def invalid(path : Array(String), where : String, invalid : Invalid) : Nil
      params = invalid.params.map { |key, value| "#{key} #{value}" }
      @problems << "#{dotted(path)} from #{where} is not valid: #{invalid.code}#{params.empty? ? "" : " (#{params.join(", ")})"}"
    end

    private def dig(path : Array(String)) : Tree
      node = @tree.as(Tree)
      path.each do |key|
        node = node.as?(Hash(String, Tree)).try(&.[key]?)
      end
      node
    end

    private def dotted(path : Array(String)) : String
      path.join('.')
    end
  end
end
