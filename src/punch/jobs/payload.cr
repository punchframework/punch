require "json"

module Punch
  # The version of a job's or an event's payload, when it is not 1, and the
  # frozen types older versions are read with:
  #
  # ```
  # @[Punch::Payloads::Version(2, from: {1 => Remind::V1})]
  # struct Remind
  #   include Punch::Job
  #   # ...
  # end
  # ```
  #
  # Each frozen type keeps the shape its version had and converts itself
  # one step on (`upgrade`), to a later frozen type or to the job itself.
  # A worker claims a job only when it can read its version, so a binary
  # leaves a newer binary's payloads alone (docs/jobs.md).
  annotation Payloads::Version
  end

  # The shape a payload had in an older version, kept so jobs written
  # then can still be read. Never change one: `punch check` compares it with
  # the lock file. It converts itself to the next shape:
  #
  # ```
  # struct Remind
  #   # Version 1: before reminders had a channel.
  #   struct V1
  #     include Punch::Payloads::Frozen
  #
  #     getter invoice_id : ID
  #
  #     def upgrade : Remind
  #       Remind.new(invoice_id, Channel::Email)
  #     end
  #   end
  # end
  # ```
  #
  # Delete it once `punch jobs:versions` shows no job of its version left.
  module Payloads::Frozen
    macro included
      include ::JSON::Serializable

      {% unless @type.struct? %}
        {% @type.raise "#{@type} includes Punch::Payloads::Frozen, so it must be a struct: it is the shape of a stored payload (lib/punch/docs/jobs.md)." %}
      {% end %}
      macro finished
        \{% upgrade = @type.methods.find { |method| method.name == "upgrade" && method.args.empty? } %}
        \{% unless upgrade && upgrade.return_type %}
          \{% @type.raise "#{@type} is a frozen payload, so it defines `upgrade` with its return type: the next version's frozen type, or the job or event itself (lib/punch/docs/jobs.md)." %}
        \{% end %}
        ::Punch::Payloads.check_strict(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
      end
    end
  end

  # Reading stored payloads across versions. Used by `Punch::Job` and
  # `Punch::Event`. :nodoc:
  module Payloads
    # A stored version this binary cannot read: newer than it knows, or
    # older than its oldest frozen type.
    class UnreadableVersion < Exception
    end

    # Readers ignore unknown fields, so that a field added by a newer
    # binary does not stop an older one.
    macro check_strict(type)
      {% if type.resolve < ::JSON::Serializable::Strict %}
        {% type.resolve.raise "#{type} is a stored payload, so it does not include JSON::Serializable::Strict: readers ignore fields they do not know, so a binary can read what a newer one wrote (lib/punch/docs/jobs.md)." %}
      {% end %}
    end

    # Defines, in the job or event *type*, its payload version and the
    # method that reads a stored payload of any version it knows, checking
    # `@[Punch::Payloads::Version]` and the frozen types' `upgrade` chain.
    macro reader(type)
      {% type = type.resolve %}
      {% version = 1 %}
      {% frozen = {} of NumberLiteral => TypeNode %}
      {% if declared = type.annotation(::Punch::Payloads::Version) %}
        {% unless declared.args.size == 1 && declared[0].is_a?(NumberLiteral) && declared[0] >= 1 && declared[0] <= 1000 %}
          {% declared.raise "@[Punch::Payloads::Version] on #{type} takes the version first, a number from 1 to 1000: @[Punch::Payloads::Version(2, from: {1 => V1})]" %}
        {% end %}
        {% for key in declared.named_args.keys %}
          {% declared.raise "@[Punch::Payloads::Version] on #{type} takes from:, not #{key}:" unless key.stringify == "from" %}
        {% end %}
        {% version = declared[0] %}
        {% if from = declared[:from] %}
          {% declared.raise "@[Punch::Payloads::Version] on #{type}: from: maps older versions to frozen types, such as from: {1 => V1}" unless from.is_a?(HashLiteral) %}
          {% for old, name in from %}
            {% unless old.is_a?(NumberLiteral) && old >= 1 && old < version %}
              {% declared.raise "@[Punch::Payloads::Version] on #{type}: from: maps versions below #{version} to frozen types; #{old} is not one" %}
            {% end %}
            {% parts = type.name(generic_args: false).split("::") %}
            {% resolved = nil %}
            {% for drop in 0..parts.size %}
              {% unless resolved %}
                {% prefix = ([""] + parts[0...(parts.size - drop)]).join("::") %}
                {% resolved = parse_type(name.global? ? name.stringify : "#{prefix.id}::#{name}").resolve? %}
              {% end %}
            {% end %}
            {% declared.raise "@[Punch::Payloads::Version] on #{type}: #{name} is not a type" unless resolved %}
            {% declared.raise "@[Punch::Payloads::Version] on #{type}: #{resolved} reads version #{old}, so it includes Punch::Payloads::Frozen" unless resolved < ::Punch::Payloads::Frozen %}
            {% frozen[old] = resolved %}
          {% end %}
        {% end %}
      {% end %}
      {% for old, frozen_type in frozen %}
        {% upgrade = frozen_type.methods.find { |method| method.name == "upgrade" && method.args.empty? } %}
        {% if upgrade && upgrade.return_type %}
          {% parts = frozen_type.name(generic_args: false).split("::") %}
          {% target = nil %}
          {% for drop in 0..parts.size %}
            {% unless target %}
              {% prefix = ([""] + parts[0...(parts.size - drop)]).join("::") %}
              {% target = parse_type(upgrade.return_type.global? ? upgrade.return_type.stringify : "#{prefix.id}::#{upgrade.return_type}").resolve? %}
            {% end %}
          {% end %}
          {% later = frozen.keys.select { |other| other > old && frozen[other] == target } %}
          {% unless target == type || !later.empty? %}
            {% upgrade.raise "#{frozen_type}#upgrade returns #{upgrade.return_type}; it reads version #{old} of #{type}, so it returns #{type} or the frozen type of a later version: every old payload must end as a #{type} (lib/punch/docs/jobs.md)." %}
          {% end %}
        {% end %}
      {% end %}

      # :nodoc:
      PUNCH_PAYLOAD_VERSION = {{ version }}

      # The versions this binary reads, newest first.
      # :nodoc:
      PUNCH_PAYLOAD_READS = { {{ version }}, {{ frozen.keys.sort_by { |old| -old }.splat }} }

      # Reads a stored payload of *version*, upgrading an older one through
      # its frozen types. Raises when the payload does not parse or the
      # version is unknown; the queue parks such a job.
      # :nodoc:
      def self.punch_payload(version : Int32, payload : String) : self
        case version
        when {{ version }} then ::Punch::Stored.from_json(self, payload)
        {% for old, frozen_type in frozen %}
          when {{ old }} then ::Punch::Payloads.upgrade(self, ::Punch::Stored.from_json({{ frozen_type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, payload))
        {% end %}
        else
          raise ::Punch::Payloads::UnreadableVersion.new("#{self} version #{version} is not readable here: this binary reads #{PUNCH_PAYLOAD_READS.join(", ")}")
        end
      end

      {% if flag?(:punch_openapi) %}
        # The schemas of the frozen types, by version, for the lock file.
        # :nodoc:
        def self.punch_payload_frozen : Hash(String, JSON::Any)
          frozen = {} of String => JSON::Any
          {% for old, frozen_type in frozen %}
            frozen[{{ old.stringify }}] = ::Punch::Payloads.schema({{ frozen_type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
          {% end %}
          frozen
        end
      {% end %}
    end

    # Converts *value* step by step to *type*.
    def self.upgrade(type : J.class, value : V) : J forall J, V
      {% if V == J %}
        value
      {% else %}
        upgrade(J, value.upgrade)
      {% end %}
    end

    # The schema of a payload type as the lock file records it: what the
    # reader requires (fields neither nilable nor defaulted) and what the
    # writer may leave out (nilable fields), with `$defs`. Called only by
    # the derivation build (`jobs:derive`).
    def self.schema(type : T.class) : JSON::Any forall T
      {% for ivar in T.instance_vars %}
        {% for member in ivar.type.union_types %}
          {% for held in [member] + member.type_vars %}
            {% if held.is_a?(TypeNode) && held.class.methods.any? { |method| method.name == "read" && method.args.size == 1 && method.args[0].restriction && method.args[0].restriction.stringify.ends_with?("Database::Row") } %}
              {% raise "#{T}##{ivar.name} holds #{held}, a whole row, in a stored payload. Store its ID and read the row when the job runs: it sees the data as it is then, and the payload stays small (lib/punch/docs/jobs.md)." %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
      registry = JSONSchema::Registry.new(payloads: true)
      reference = registry.schema(T)
      JSONSchema.object({"$ref" => reference["$ref"], "$defs" => JSON::Any.new(registry.definitions)})
    end
  end
end
