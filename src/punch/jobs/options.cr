module Punch
  class Job::Queue
    # Checks a job's or a deferred subscriber's option annotations at
    # compile time. Called from `Punch::Job` and `Punch::Subscriber`.
    # :nodoc:
    macro check_options(type, name)
      {% type = type.resolve %}
      {% if options = type.annotation(::Punch::Job::Options) %}
        {% for key in options.named_args.keys %}
          {% options.raise "@[Punch::Job::Options] on #{type} takes queue:, attempts:, and priority:, not #{key}:" unless %w[queue attempts priority].includes?(key.stringify) %}
        {% end %}
        {% unless options.args.empty? %}
          {% options.raise "@[Punch::Job::Options] on #{type} takes named arguments only: queue:, attempts:, priority:" %}
        {% end %}
        {% if queue = options[:queue] %}
          {% options.raise "@[Punch::Job::Options] on #{type}: queue: is a name of lowercase letters, digits, and _ (\"mail\"), got #{queue}" unless queue.is_a?(StringLiteral) && queue =~ /\A[a-z][a-z0-9_]{0,62}\z/ %}
        {% end %}
        {% if attempts = options[:attempts] %}
          {% options.raise "@[Punch::Job::Options] on #{type}: attempts: is a number from 1 to 100, got #{attempts}" unless attempts.is_a?(NumberLiteral) && attempts >= 1 && attempts <= 100 %}
        {% end %}
        {% if priority = options[:priority] %}
          {% options.raise "@[Punch::Job::Options] on #{type}: priority: is a number from -100 to 100, got #{priority}" unless priority.is_a?(NumberLiteral) && priority >= -100 && priority <= 100 %}
        {% end %}
      {% end %}
      {% if limit = type.annotation(::Punch::Job::Concurrency) %}
        {% limit.raise "@[Punch::Job::Concurrency] on #{type} takes the limit first: @[Punch::Job::Concurrency(1, by: :invoice_id)]" unless limit.args.size == 1 && limit[0].is_a?(NumberLiteral) && limit[0] >= 1 && limit[0] <= 1000 %}
        {% for key in limit.named_args.keys %}
          {% limit.raise "@[Punch::Job::Concurrency] on #{type} takes by: and group:, not #{key}:" unless %w[by group].includes?(key.stringify) %}
        {% end %}
        {% if group = limit[:group] %}
          {% limit.raise "@[Punch::Job::Concurrency] on #{type}: group: is a name of lowercase letters, digits, and _, got #{group}" unless group.is_a?(StringLiteral) && group =~ /\A[a-z][a-z0-9_]{0,62}\z/ %}
        {% end %}
        {% if by = limit[:by] %}
          {% limit.raise "@[Punch::Job::Concurrency] on #{type}: by: names a field, such as by: :invoice_id, got #{by}" unless by.is_a?(SymbolLiteral) %}
          {% if type < ::Punch::Job %}
            {% limit.raise "@[Punch::Job::Concurrency] on #{type}: by: :#{by.id} is not a field of the job" unless type.methods.any? { |method| method.name == by.id && method.args.empty? } %}
          {% end %}
        {% end %}
      {% end %}
      {% if recurring = type.annotation(::Punch::Job::Recurring) %}
        {% recurring.raise "@[Punch::Job::Recurring] is for jobs; #{type} is not one" unless type < ::Punch::Job %}
        {% unless recurring.args.empty? && recurring.named_args.size == 1 && (recurring[:cron] || recurring[:every]) %}
          {% recurring.raise "@[Punch::Job::Recurring] on #{type} takes one of cron: \"0 3 * * *\" or every: 1.hour" %}
        {% end %}
        {% recurring.raise "@[Punch::Job::Recurring] on #{type}: cron: is a string, such as \"0 3 * * *\"" if recurring[:cron] && !recurring[:cron].is_a?(StringLiteral) %}
        {% recurring.raise "@[Punch::Job::Recurring] on #{type}: Recurring is given once; a job has one schedule" if type.annotations(::Punch::Job::Recurring).size > 1 %}
      {% end %}
    end

    # The queue, attempts, and priority of *type* (a job or a deferred
    # subscriber), from its `@[Punch::Job::Options]`.
    def self.options(type : T.class) : {String, Int32, Int32} forall T
      {% begin %}
        {% options = T.annotation(::Punch::Job::Options) %}
        { {{ (options && options[:queue]) || DEFAULT_QUEUE }}, {{ (options && options[:attempts]) || DEFAULT_ATTEMPTS }}, {{ (options && options[:priority]) || 0 }} }
      {% end %}
    end

    # The concurrency key and limit of *type* for *payload* (the job, or
    # the event of a deferred subscriber), from its `@[Punch::Job::Concurrency]`.
    def self.concurrency(type : T.class, payload : P) : {String?, Int32?} forall T, P
      {% begin %}
        {% limit = T.annotation(::Punch::Job::Concurrency) %}
        {% if limit %}
          { {{ limit[:group] || T.name.stringify }}{% if limit[:by] %} + ":" + Routing.segment(payload.{{ limit[:by].id }}){% end %}, {{ limit[0] }} }
        {% else %}
          {nil, nil}
        {% end %}
      {% end %}
    end

    # The row of deferred subscriber *subscriber* for *event*: its type
    # is `Subscriber(Event)`, its payload the event.
    def self.deferred_entry(subscriber : S.class, event : E, run_at : Time) : Entry forall S, E
      queue, attempts, priority = options(S)
      key, limit = concurrency(S, event)
      Entry.new(queue: queue, type: {{ "#{S}(#{E})" }}, version: E::PUNCH_PAYLOAD_VERSION, payload: ::Punch::Stored.json(event), priority: priority,
        run_at: run_at, max_attempts: attempts, concurrency_key: key, concurrency_limit: limit,
        traceparent: Trace.current.span_context.try(&.traceparent))
    end

    # The row for *job*, due at *run_at*.
    def self.entry(job : J, run_at : Time, *, unique_key : String? = nil, traceparent : String? = nil) : Entry forall J
      {% if J.union? %}
        # A variable of several job types: each job by its own.
        case job
        {% for type in J.union_types %}
          in {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then entry(job, run_at, unique_key: unique_key, traceparent: traceparent)
        {% end %}
        end
      {% else %}
        entry_of(job, run_at, unique_key, traceparent)
      {% end %}
    end

    private def self.entry_of(job : J, run_at : Time, unique_key : String?, traceparent : String?) : Entry forall J
      queue, attempts, priority = options(J)
      key, limit = concurrency(J, job)
      Entry.new(queue: queue, type: {{ J.name.stringify }}, version: J::PUNCH_PAYLOAD_VERSION, payload: ::Punch::Stored.json(job), priority: priority,
        run_at: run_at, max_attempts: attempts, unique_key: unique_key, concurrency_key: key, concurrency_limit: limit,
        traceparent: traceparent)
    end
  end
end
