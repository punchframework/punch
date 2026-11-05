require "./crypto"
require "./credentials/master_key"
require "./credentials/encrypted_file"
require "./credentials/tree"
require "./credentials/source"

module Punch
  # The credentials an app needs, declared as a type and checked at boot.
  # Each value is looked up in the environment first, then in the
  # environment's encrypted file, `config/credentials/<env>.yml.enc`, which
  # is compiled into the binary; only its key is supplied at runtime.
  #
  # ```
  # struct Invoicing::Credentials
  #   include Punch::Credentials
  #
  #   getter stripe : Stripe # a group: the `stripe:` mapping in the file
  #   getter support_email : Punch::Email
  #
  #   struct Stripe
  #     include Punch::Credentials
  #     getter secret_key : Punch::Secret(String) # STRIPE__SECRET_KEY, else stripe.secret_key
  #     getter timeout : Int32 = 10               # optional, with a default
  #   end
  # end
  #
  # Punch.credentials Invoicing::Credentials
  #
  # Invoicing::Credentials.current.stripe.secret_key.unwrap
  # ```
  #
  # Three rules:
  # 1. The variable is the path in capitals joined by `__`: `stripe.secret_key`
  #    is `STRIPE__SECRET_KEY`. A set variable wins over the file.
  # 2. A field is required unless it is nilable or has a default. Every
  #    missing or malformed value stops the boot, all reported at once,
  #    and so does a key in the file that no field declares.
  # 3. Anything that must not leak is a `Punch::Secret(T)`: `creds:check`
  #    shows where it came from but not its value.
  #
  # Field types: `String`, `Bool`, `Int32`, `Int64`, `Float64`, enums (by
  # snake_case name), domain primitives (`Punch::Primitive`), `Punch::Secret`
  # of one of these, nested credentials types (groups), and the key ring,
  # `getter secret_key_base : Punch::KeyRing`, which becomes
  # `Punch::KeyRing.current`, and the key of public IDs,
  # `getter public_id_key : Punch::PublicIDKey`. Any other type does not
  # compile.
  module Credentials
    DIRECTORY   = "config/credentials"
    ENVIRONMENT = /\A[a-z][a-z0-9_]*\z/

    # Raised when code reads `current` before the boot loaded it: a bug.
    class NotLoaded < Exception
    end

    def self.file(environment : String, directory : String = DIRECTORY) : String
      File.join(directory, "#{environment}.yml.enc")
    end

    def self.key_file(environment : String, directory : String = DIRECTORY) : String
      File.join(directory, "#{environment}.key")
    end

    # The environment variable of the credential at *path*.
    def self.variable(path : Array(String)) : String
      path.join("__").upcase
    end

    # Whether the app declared a credentials type with `Punch.credentials`.
    # Replaced by that macro.
    def self.declared? : Bool
      false
    end

    # The environments whose files are compiled in. Replaced by
    # `Punch.credentials`.
    def self.environments : Array(String)
      [] of String
    end

    # Where the credentials loaded at boot came from, field by field, for
    # the ops console; values of secrets are not in it.
    class_property loaded : Source? = nil

    # Loads the app's credentials for *environment* and makes them
    # `current`; the source holds the problems, if any. `nil` when the app
    # declares none. Replaced by `Punch.credentials`.
    def self.boot(environment : String, env = ENV) : Source?
      nil
    end

    macro included
      @@current : self?

      # The credentials loaded at boot.
      def self.current : self
        @@current || raise ::Punch::Credentials::NotLoaded.new("#{self} has not been loaded. Applications load it at boot; specs call Punch::Spec.credentials.")
      end

      # Sets the credentials for the process; done once at boot, or by a spec.
      def self.current=(value : self) : self
        @@current = value
      end

      # The credentials in *source*, or every problem with them.
      def self.load(source : ::Punch::Credentials::Source) : self | Array(String)
        value = new(__punch_credentials: source, __punch_path: [] of String)
        source.problems.empty? ? value : source.problems
      end
    end

    # Fields that fail are left uninitialized; the instance is then
    # discarded and `load` returns the problems instead.
    def initialize(*, __punch_credentials source : ::Punch::Credentials::Source, __punch_path path : Array(String))
      __punch_check_credential_types
      {% begin %}
      source.check_keys(path, {{ @type.instance_vars.map(&.name.stringify) }} of String)
      {% for ivar in @type.instance_vars %}
        {% type = ivar.type.union_types.reject { |member| member == Nil }.first %}
        {% wrapped = type.name(generic_args: false) == "Punch::Secret" %}
        {% inner = wrapped ? type.type_vars.first : type %}
        {% secret = wrapped || inner == ::Punch::KeyRing || inner == ::Punch::PublicIDKey %}
        %path{ivar.name} = path + [{{ ivar.name.stringify }}]
        {% if inner < ::Punch::Credentials %}
          @{{ ivar.name }} = {{ inner.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new(__punch_credentials: source, __punch_path: %path{ivar.name})
        {% else %}
          if %found{ivar.name} = source.lookup(%path{ivar.name})
            %raw{ivar.name}, %origin{ivar.name}, %where{ivar.name} = %found{ivar.name}
            case %read{ivar.name} = ::Punch::Credentials.parse_value({{ inner.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, %raw{ivar.name})
            in ::Punch::Invalid
              source.invalid(%path{ivar.name}, %where{ivar.name}, %read{ivar.name})
              {% unless ivar.has_default_value? %}
                @{{ ivar.name }} = uninitialized {{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              {% end %}
            in {{ inner.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              source.found(%path{ivar.name}, %origin{ivar.name}, %where{ivar.name}, {{ secret }}, %read{ivar.name}.to_s)
              @{{ ivar.name }} = {% if wrapped %}::Punch::Secret.new(%read{ivar.name}){% else %}%read{ivar.name}{% end %}
            end
          else
            {% if ivar.has_default_value? %}
              source.defaulted(%path{ivar.name}, {{ secret }}, @{{ ivar.name }}.to_s)
            {% elsif ivar.type.nilable? %}
              source.absent(%path{ivar.name}, {{ secret }})
              @{{ ivar.name }} = nil
            {% else %}
              source.missing(%path{ivar.name})
              @{{ ivar.name }} = uninitialized {{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
            {% end %}
          end
        {% end %}
      {% end %}
      {% end %}
    end

    # The key ring among the fields (`secret_key_base`), if any.
    def __punch_key_ring : ::Punch::KeyRing?
      {% begin %}
        {% ring = @type.instance_vars.find { |ivar| ivar.type == ::Punch::KeyRing } %}
        {% if ring %}@{{ ring.name }}{% else %}nil{% end %}
      {% end %}
    end

    # The key of public IDs among the fields (`public_id_key`), if any.
    def __punch_public_id_key : ::Punch::PublicIDKey?
      {% begin %}
        {% key = @type.instance_vars.find { |ivar| ivar.type == ::Punch::PublicIDKey } %}
        {% if key %}@{{ key.name }}{% else %}nil{% end %}
      {% end %}
    end

    # Configures `Punch::Mailer` from the mail settings among the fields
    # (`getter mail : Punch::Mailer::Settings`), if any.
    def __punch_configure_mail : Nil
      {% begin %}
        {% settings = @type.instance_vars.find { |ivar| ivar.type == ::Punch::Mailer::Settings } %}
        {% if settings %}::Punch::Mailer.configure(@{{ settings.name }}, {{ settings.name.stringify }}){% end %}
      {% end %}
    end

    # Configures `Punch::Upload` from the upload settings among the fields
    # (`getter uploads : Punch::Upload::Settings`), if any.
    def __punch_configure_uploads : Nil
      {% begin %}
        {% settings = @type.instance_vars.find { |ivar| ivar.type == ::Punch::Upload::Settings } %}
        {% if settings %}::Punch::Upload.configure(@{{ settings.name }}, {{ settings.name.stringify }}){% end %}
      {% end %}
    end

    # The value of type *type* in *raw*.
    def self.parse_value(type : KeyRing.class, raw : String) : KeyRing | Invalid
      KeyRing.parse(raw)
    end

    def self.parse_value(type : PublicIDKey.class, raw : String) : PublicIDKey | Invalid
      PublicIDKey.parse(raw)
    end

    def self.parse_value(type : T.class, raw : String) forall T
      Input::Read.string(T, raw)
    end

    # Makes *value* current, with its key ring and its mail settings if it
    # has them. Mail settings that do not fit together are reported by
    # `Punch::Mailer.problems`.
    def self.install(value : T) : T forall T
      value.__punch_key_ring.try { |ring| KeyRing.current = ring }
      value.__punch_public_id_key.try(&.install)
      Mailer.problems.clear
      value.__punch_configure_mail
      value.__punch_configure_uploads
      T.current = value
    end

    # What stops the boot of an app with public IDs but without their key.
    def self.public_id_problems(value) : Array(String)
      prefixes = TypedID.public_prefixes
      return [] of String if prefixes.empty? || value.__punch_public_id_key

      ["public_id_key: missing; the app has public IDs (#{prefixes.join(", ")}). Declare `getter public_id_key : Punch::PublicIDKey` and run 'punch keys:public-id' (lib/punch/docs/keys.md)."]
    end

    # Fails compilation, naming the field, when a field has a type that
    # credentials cannot hold.
    private def __punch_check_credential_types : Nil
      {% for ivar in @type.instance_vars %}
        {% types = ivar.type.union_types.reject { |member| member == Nil } %}
        {% type = types.first %}
        {% secret = types.size == 1 && type.name(generic_args: false) == "Punch::Secret" %}
        {% inner = secret ? type.type_vars.first : type %}
        {% scalar = [String, Bool, Int32, Int64, Float64].includes?(inner) ||
                    (inner < Enum && !inner.annotation(Flags)) ||
                    inner.ancestors.any? { |a| a.name(generic_args: false) == "Punch::Primitive" } %}
        {% group = !secret && inner < ::Punch::Credentials %}
        {% ring = !secret && inner == ::Punch::KeyRing %}
        {% public_id_key = !secret && inner == ::Punch::PublicIDKey %}
        {% if public_id_key && (ivar.name != "public_id_key" || ivar.type.nilable? || ivar.has_default_value?) %}
          {% raise "Punch: #{@type}##{ivar.name} is the key of public IDs; declare it as `getter public_id_key : Punch::PublicIDKey`, required, so `punch keys:public-id` finds it." %}
        {% end %}
        {% if ring && (ivar.name != "secret_key_base" || ivar.type.nilable? || ivar.has_default_value?) %}
          {% raise "Punch: #{@type}##{ivar.name} is a key ring; declare it as `getter secret_key_base : Punch::KeyRing`, required, so the keys: commands and SECRET_KEY_BASE find it." %}
        {% end %}
        {% if types.size != 1 || !(scalar || group || ring || public_id_key) %}
          {% raise "Punch: #{@type}##{ivar.name} has type #{ivar.type}, which credentials cannot hold.\n" +
                   "Use String, Bool, Int32, Int64, Float64, an enum, a domain primitive (Punch::Primitive),\n" +
                   "Punch::Secret of one of these, Punch::KeyRing, Punch::PublicIDKey, or a nested type that includes Punch::Credentials (a group).\n" +
                   "Make it nilable (`T?`) or give it a default to make it optional." %}
        {% end %}
        {% if group && (ivar.type.nilable? || ivar.has_default_value?) %}
          {% raise "Punch: the group #{@type}##{ivar.name} cannot be optional. Make its fields optional instead." %}
        {% end %}
      {% end %}
    end
  end

  # Declares the app's credentials type and compiles in the encrypted file
  # of each environment in *environments* (`config/credentials/<env>.yml.enc`,
  # relative to where the compiler runs). Call it once, at the top level:
  #
  # ```
  # Punch.credentials Invoicing::Credentials
  # Punch.credentials Invoicing::Credentials, environments: %w[development test staging production]
  # ```
  macro credentials(type, environments = ["development", "test", "production"])
    {% for environment in environments %}
      {% raise "Punch.credentials: '#{environment.id}' is not an environment name (lowercase letters, digits, and _)" unless environment =~ /\A[a-z][a-z0-9_]*\z/ %}
    {% end %}

    {% resolved = parse_type(type.stringify.gsub(::Punch::NAME_STARTS, "::")).resolve %}
    module ::Punch::Credentials
      def self.declared? : Bool
        true
      end

      def self.environments : Array(String)
        {{ environments }} of String
      end

      def self.embedded(environment : String) : String?
        case environment
        {% for environment in environments %}
        when {{ environment }} then {{ read_file?("config/credentials/" + environment + ".yml.enc") }}
        {% end %}
        end
      end

      def self.boot(environment : String, env = ENV) : ::Punch::Credentials::Source?
        source = ::Punch::Credentials::Source.open(environment, embedded(environment), env, declared: environments.includes?(environment))
        ::Punch::Credentials.loaded = source
        case value = {{ resolved.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.load(source)
        in {{ resolved.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
          ::Punch::Credentials.install(value)
          source.problems.concat(::Punch::Credentials.public_id_problems(value))
          source.problems.concat(::Punch::Mailer.problems)
          source.problems.concat(::Punch::Mailer.environment_problems(environment))
          source.problems.concat(::Punch::Upload.problems(environment))
        in Array(String)
        end
        source
      end
    end
  end
end
