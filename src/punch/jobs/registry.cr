module Punch
  class Job::Queue
    # Every job type this binary can run, by the name stored in `queue.db`,
    # resolved at compile time, with the newest payload version it reads. A
    # worker claims only these, and only up to that version, so a binary
    # never takes a job it does not know or a payload written by a newer
    # binary (during a handover or after a rollback). :nodoc:
    module Registry
      # Parses the payload of the given version and performs the job.
      alias Runner = Proc(Int32, String, Job::Context, Ran)

      # What running a job came to, before it is recorded.
      alias Ran = Job::Result | Unreadable | Job::Steps::Pause

      # The payload did not parse into the job's type, or its version is
      # one this binary does not read: the job is parked.
      struct Unreadable
        getter error : String

        def initialize(@error : String)
        end
      end

      class_getter runners : Hash(String, Runner) { build }

      # The names with the newest payload version each reads, for claiming.
      class_getter types : Hash(String, Int32) { build_versions }

      # The payload versions each type reads, newest first.
      class_getter reads : Hash(String, Array(Int32)) { build_reads }

      private def self.build : Hash(String, Runner)
        runners = {} of String => Runner
        {% for job in ::Punch::Job.includers %}
          {% for type in [job] + job.all_subclasses %}
            {% unless type.abstract? %}
              runners[{{ type.name.stringify }}] = ->(version : Int32, payload : String, context : Job::Context) { Registry.run({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, version, payload, context).as(Ran) }
            {% end %}
          {% end %}
        {% end %}
        {% for subscriber in ::Punch::Subscriber.includers.uniq %}
          {% if (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred %}
            {% events = [] of TypeNode %}
            {% for type in ::Punch::Event.includers %}
              {% events << type unless type.abstract? %}
              {% for sub in type.all_subclasses %}
                {% events << sub unless sub.abstract? %}
              {% end %}
            {% end %}
            {% for event in events.uniq %}
              {% if subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                {% if (limit = subscriber.annotation(::Punch::Job::Concurrency)) && limit[:by] && !event.has_method?(limit[:by].id) %}
                  {% limit.raise "@[Punch::Job::Concurrency] on #{subscriber}: by: :#{limit[:by].id} is not a field of #{event}, which it subscribes to" %}
                {% end %}
                runners[{{ "#{subscriber}(#{event})" }}] = ->(version : Int32, payload : String, context : Job::Context) { Registry.deliver({{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, {{ event.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, version, payload, context).as(Ran) }
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        runners
      end

      private def self.build_versions : Hash(String, Int32)
        build_reads.transform_values(&.first)
      end

      private def self.build_reads : Hash(String, Array(Int32))
        reads = {} of String => Array(Int32)
        {% for job in ::Punch::Job.includers %}
          {% for type in [job] + job.all_subclasses %}
            {% unless type.abstract? %}
              reads[{{ type.name.stringify }}] = {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_PAYLOAD_READS.to_a
            {% end %}
          {% end %}
        {% end %}
        {% for subscriber in ::Punch::Subscriber.includers.uniq %}
          {% if (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred %}
            {% for type in ::Punch::Event.includers %}
              {% for event in [type] + type.all_subclasses %}
                {% if !event.abstract? && subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                  reads[{{ "#{subscriber}(#{event})" }}] = {{ event.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_PAYLOAD_READS.to_a
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        reads.keys.sort!.to_h { |name| {name, reads[name]} }
      end

      # Runs a deferred subscriber on the event in *payload*: the job of
      # one subscriber for one event. One small method per pair.
      def self.deliver(subscriber : S.class, event : E.class, version : Int32, payload : String, context : Job::Context) : Ran forall S, E
        parsed = read(E, version, payload)
        return parsed if parsed.is_a?(Unreadable)

        span = Trace.current
        if span.recording?
          span.set("punch.subscriber", {{ S.name.stringify }})
          span.set("punch.event", {{ E.name.stringify }})
          span.set("punch.delivery", "deferred")
        end
        Registry.result(S, S.new.call(parsed, context))
      end

      # The lock file's content: which payload each stored type carries, and
      # each payload's version and schemas. Called only in the derivation
      # build (`-Dpunch_openapi`), like OpenAPI.
      def self.lock : JSON::Any
        types = {} of String => JSON::Any
        payloads = {} of String => JSON::Any
        {% for job in ::Punch::Job.includers %}
          {% for type in [job] + job.all_subclasses %}
            {% unless type.abstract? %}
              types[{{ type.name.stringify }}] = JSON::Any.new({{ type.name.stringify }})
              payloads[{{ type.name.stringify }}] ||= Registry.locked({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
            {% end %}
          {% end %}
        {% end %}
        {% for subscriber in ::Punch::Subscriber.includers.uniq %}
          {% if (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred %}
            {% for type in ::Punch::Event.includers %}
              {% for event in [type] + type.all_subclasses %}
                {% if !event.abstract? && subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                  types[{{ "#{subscriber}(#{event})" }}] = JSON::Any.new({{ event.name.stringify }})
                  payloads[{{ event.name.stringify }}] ||= Registry.locked({{ event.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        lock = {
          "types"    => JSON::Any.new(types.keys.sort!.to_h { |name| {name, types[name]} }),
          "payloads" => JSON::Any.new(payloads.keys.sort!.to_h { |name| {name, payloads[name]} }),
        }
        documents = Registry.documents
        lock["documents"] = JSON::Any.new(documents.keys.sort!.to_h { |name| {name, documents[name]} }) unless documents.empty?
        JSON::Any.new(lock)
      end

      # Composites stored as JSON documents (docs/composites.md): each one's
      # version, schema, and the schemas of its frozen types.
      # :nodoc:
      def self.documents : Hash(String, JSON::Any)
        documents = {} of String => JSON::Any
        {% for type in ::Punch::Composite.includers %}
          {% if type.has_constant?("PUNCH_DOCUMENT") && type.constant("PUNCH_DOCUMENT") %}
            documents[{{ type.name.stringify }}] = Registry.document({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
          {% end %}
        {% end %}
        documents
      end

      # :nodoc:
      def self.document(type : T.class) : JSON::Any forall T
        entry = {"version" => JSON::Any.new(T::PUNCH_VERSION.to_i64), "schema" => Payloads.schema(T)}
        frozen = {} of String => JSON::Any
        {% if T.has_constant?("PUNCH_FROZEN") %}
          {% for version, frozen_type in T.constant("PUNCH_FROZEN") %}
            frozen[{{ version.stringify }}] = Payloads.schema({{ frozen_type }})
          {% end %}
        {% end %}
        entry["frozen"] = JSON::Any.new(frozen) unless frozen.empty?
        JSON::Any.new(entry)
      end

      # :nodoc:
      def self.locked(type : T.class) : JSON::Any forall T
        entry = {"version" => JSON::Any.new(T::PUNCH_PAYLOAD_VERSION.to_i64), "schema" => Payloads.schema(T)}
        frozen = T.punch_payload_frozen
        entry["frozen"] = JSON::Any.new(frozen.keys.sort_by!(&.to_i).to_h { |version| {version, frozen[version]} }) unless frozen.empty?
        {% if T < ::Punch::Job::Stepped %}
          entry["steps"] = T.punch_steps_lock
        {% end %}
        JSON::Any.new(entry)
      end

      # One job type as `jobs:types` shows it.
      record Description, type : String, queue : String, attempts : Int32, priority : Int32,
        concurrency : String?, concurrency_limit : Int32? do
        include JSON::Serializable
      end

      # Every job type with its options, by name.
      def self.descriptions : Array(Description)
        list = [] of Description
        {% for job in ::Punch::Job.includers %}
          {% for type in [job] + job.all_subclasses %}
            {% unless type.abstract? %}
              list << Registry.describe({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, {{ type.name.stringify }})
            {% end %}
          {% end %}
        {% end %}
        {% for subscriber in ::Punch::Subscriber.includers.uniq %}
          {% if (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred %}
            {% for type in ::Punch::Event.includers %}
              {% for event in [type] + type.all_subclasses %}
                {% if !event.abstract? && subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                  list << Registry.describe({{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, {{ "#{subscriber}(#{event})" }})
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        list.uniq!(&.type).sort_by!(&.type)
      end

      # :nodoc:
      def self.describe(type : J.class, name : String) : Description forall J
        queue, attempts, priority = Job::Queue.options(J)
        {% begin %}
          {% limit = J.annotation(::Punch::Job::Concurrency) %}
          Description.new(name, queue, attempts, priority,
            {% if limit %} {{ (limit[:group] || J.name.stringify) + (limit[:by] ? " by #{limit[:by].id}" : "") }}, {{ limit[0] }} {% else %} nil, nil {% end %})
        {% end %}
      end

      # One small method per job type (compile-time budget).
      def self.run(type : J.class, version : Int32, payload : String, context : Job::Context) : Ran forall J
        job = read(J, version, payload)
        return job if job.is_a?(Unreadable)

        Registry.result(J, job.perform(context))
      end

      # The payload as a *type*, upgraded from an older version through its
      # frozen types. Any failure, a conversion that raises included, makes
      # it unreadable: the job is parked, not retried, until a binary that
      # reads it is deployed.
      def self.read(type : T.class, version : Int32, payload : String) : T | Unreadable forall T
        T.punch_payload(version, payload)
      rescue ex
        Unreadable.new("#{T} version #{version}: #{ex.is_a?(Payloads::UnreadableVersion) ? "" : "the payload does not parse: #{ex.class}: "}#{ex.message}")
      end

      # Checks what `perform` returns.
      def self.result(type : J.class, value : R) : Ran forall J, R
        {% raise "#{J}#perform returns #{R}; a job returns Punch::Job::Result: nil when done, Punch::Job::Retry, or Punch::Job::Discard (lib/punch/docs/jobs.md)." unless R <= ::Punch::Job::Result || (J < ::Punch::Job::Stepped && R <= ::Punch::Job::Steps::Outcome) %}
        value
      end
    end
  end
end
