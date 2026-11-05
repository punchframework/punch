module Punch::Spec
  # One job run by `perform_jobs`.
  record Performed, id : Int64, type : String, outcome : Job::Queue::Outcome, error : String?

  @@queue : Job::Queue?
  @@queue_lock = Mutex.new

  # This example's queue: an in-memory `queue.db`, opened on first use,
  # attached as `Punch::Job::Queue.current`, and closed after the example.
  def self.queue : Job::Queue
    @@queue_lock.synchronize do
      @@queue ||= begin
        database = Database.memory(name: "queue", config: Database::Config.new(readers: 2))
        Job::Queue.new(database).tap { |queue| Job::Queue.attach(queue) }
      end
    end
  end

  # Runs every due job of this example's queue now, one after another in
  # this fiber, against `Punch::Spec.db`, until none is due: follow-ups a
  # job enqueues run too, retries wait for their backoff (advance the
  # `clock`). Returns what ran, in order.
  #
  # With *interrupt_every*, each job with steps is stopped after every so
  # many saves, as a deploy would stop it, and resumed on the next run:
  # `perform_jobs(interrupt_every: 1)` checks that the job ends the same
  # wherever it is stopped (docs/jobs.md, "Long jobs: steps").
  def self.perform_jobs(*, limit : Int32 = 1000, interrupt_every : Int32? = nil) : Array(Performed)
    performed = [] of Performed
    loop do
      hand_over
      claimed = queue.claim("spec", 1, Job::Queue::Registry.types).first? || break
      raise "perform_jobs ran #{limit} jobs and more are due; a job may enqueue itself" if performed.size >= limit
      outcome = Job::Queue.perform(claimed, queue, db, "spec", job_tracer, interrupt_every: interrupt_every)
      performed << Performed.new(claimed.id, claimed.type, outcome, queue.find(claimed.id).try(&.error))
    end
    performed
  end

  # Records job runs in `Punch::Spec.ops` once an example opened it;
  # off otherwise.
  private def self.job_tracer : Trace::Tracer
    ops? ? Trace::Tracer.new(events: [OpsEvents.new] of Trace::EventSink) : Trace::Tracer.off
  end

  # The saved progress of the job with *id*, a job with steps, in
  # `Punch::Spec.db`: `nil` before its first save.
  #
  # ```
  # progress = Punch::Spec.job_progress(id).should_not be_nil
  # progress.step.should eq("copy_rows")
  # progress.cursor(Rows::ID).should eq(last_copied)
  # ```
  def self.job_progress(id : Int64) : Job::Steps::Saved?
    row = queue.find(id) || raise ArgumentError.new("no job #{id} in this example's queue")
    key = row.unique_key || "job-#{id}"
    db.read { |reader| Job::Steps::Progress.load(reader, key) }
  end

  # The jobs of *type* waiting in this example's queue (due or not),
  # parsed, oldest first; committed outbox entries are handed over first.
  def self.enqueued(type : T.class) : Array(T) forall T
    hand_over
    queue.list(type: {{ T.name.stringify }}, limit: 10_000).select(&.state.==("ready")).reverse!.map { |row| T.punch_payload(row.version, row.payload) }
  end

  # Reads *payload* as it was stored at payload *version* of *type* (a job
  # or an event), through the frozen types, as a worker would: for specs
  # of a conversion (docs/jobs.md).
  #
  # ```
  # job = Punch::Spec.read_payload(Remind, 1, %({"invoice_id": 7}))
  # job.channel.should eq(Remind::Channel::Email)
  # ```
  def self.read_payload(type : T.class, version : Int32, payload : String) : T forall T
    T.punch_payload(version, payload)
  end

  # Hands committed outbox entries of `Punch::Spec.db` over to this
  # example's queue, as the relay does after a commit. Returns how many.
  # `perform_jobs` and `enqueued` do it first.
  def self.hand_over : Int32
    return 0 unless Job::Outbox.present?(db)

    Job::Outbox::Relay.new(db, queue).drain
  end

  # The outbox handle of *operation* for a write it runs in, for specs
  # that call a Command directly:
  #
  # ```
  # db.write { |writer| Invoices::Send.new.call(input, writer, ..., Punch::Spec.jobs(Invoices::Send, writer)) }
  # ```
  def self.jobs(operation : O.class, writer : Writer) forall O
    {% begin %}
      {% handle = parse_type("::#{O}::PunchCallExtras").resolve.type_vars.find { |type| type.name(generic_args: false) == "Punch::Jobs" } %}
      {% raise "#{O}#call takes no Punch::Jobs, so it enqueues nothing." unless handle %}
      {{ handle.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.for_transaction(writer)
    {% end %}
  end

  # :nodoc:
  def self.close_queue : Nil
    queue = @@queue_lock.synchronize { @@queue.tap { @@queue = nil } }
    return unless queue

    Job::Queue.detach
    queue.database.close
  end
end

Punch::Job::Queue.fallback = -> { Punch::Spec.queue }
Spec.after_each { Punch::Spec.close_queue }

module Punch::Spec
  # What `enqueue` matches: a block after which this example's queue holds
  # new waiting jobs of type *T* with these field values (and due at
  # *at*), *times* times when given. Outbox entries are handed over
  # before and after.
  class EnqueueExpectation(T, F)
    @new = [] of {Job::Queue::Row, T}
    @matching = [] of T

    def initialize(@times : Int32?, @at : Time?, @fields : F)
    end

    def match(actual : Proc) : Bool
      name = {{ T.name.stringify }}
      Spec.hand_over
      before = Spec.queue.list(type: name, limit: 10_000).map(&.id).to_set
      actual.call
      Spec.hand_over
      rows = Spec.queue.list(type: name, limit: 10_000).reject { |row| before.includes?(row.id) || row.state != "ready" }.reverse!
      @new = rows.map { |row| {row, T.punch_payload(row.version, row.payload)} }
      # The queue keeps due times to the millisecond.
      due = @at.try(&.to_unix_ms)
      @matching = @new.select { |row, job| (due.nil? || row.run_at.to_unix_ms == due) && fields?(job) }.map(&.[1])
      (times = @times) ? @matching.size == times : !@matching.empty?
    end

    def failure_message(actual : Proc) : String
      got = @new.map { |row, job| "#{job.inspect} at #{row.run_at}" }
      "Expected the block to enqueue #{describe}\n     got: #{got.empty? ? "no #{T} jobs" : got.join(", ")}"
    end

    def negative_failure_message(actual : Proc) : String
      "Expected the block not to enqueue #{describe}\n     got: #{@matching.map(&.inspect).join(", ")}"
    end

    private def describe : String
      String.build do |io|
        io << (@times.try { |times| "#{times} × " } || "") << T
        io << " with " << @fields.to_s.lchop('{').rchop('}') unless @fields.empty?
        @at.try { |due| io << " at " << due }
      end
    end

    private def fields?(job : T) : Bool
      {% for key in F.keys %}
        {% unless T.has_method?(key) || T.ancestors.any?(&.has_method?(key)) %}
          {% raise "enqueue(#{T}, #{key}: …): #{T} has no `#{key}`" %}
        {% end %}
        return false unless job.{{ key }} == @fields[{{ key.symbolize }}]
      {% end %}
      true
    end
  end
end

# `->{ … }.should enqueue(Billing::Invoices::Remind, invoice_id: id)`: after
# the block, this example's queue holds at least one new waiting job of
# this type with these field values, through the outbox or directly;
# `times: n` for exactly *n*, `at:` for the time it is due (to the
# millisecond).
def enqueue(type : T.class, *, times : Int32? = nil, at : Time? = nil, **fields) forall T
  Punch::Spec::EnqueueExpectation(T, typeof(fields)).new(times, at, fields)
end
