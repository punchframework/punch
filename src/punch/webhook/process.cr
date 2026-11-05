module Punch::Webhook
  # How long processed, ignored, discarded, and rejected invocations are kept
  # (`PUNCH_WEBHOOK_RETENTION_DAYS`): their raw bodies often hold personal
  # data.
  class_property retention : Time::Span = 30.days

  # Whether this binary has a provider.
  def self.used? : Bool
    {{ !::Punch::Webhook::Inbound.all_subclasses.reject(&.abstract?).empty? }}
  end

  # The providers by name, with how they verify, for `punch webhooks`.
  def self.providers : Array({String, String, String})
    list = [] of {String, String, String}
    {% for provider in ::Punch::Webhook::Inbound.all_subclasses.reject(&.abstract?).sort_by(&.name.stringify) %}
      list << { {{ provider.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_PROVIDER, {{ provider.stringify }}, {{ provider.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_VERIFICATION.to_s }
    {% end %}
    list
  end

  # The endpoint's work: verify at the edge if the provider does, store the
  # request under its idempotency key, and enqueue its processing through
  # the outbox in the same transaction, so a stored delivery is processed
  # even after a crash. A repeat answers 204 and stores nothing; the same
  # key with another payload 409.
  def self.receive(provider : P, request : RawRequest, db : Writer, jobs : Jobs(Process)) : Received forall P
    verification = P::PUNCH_VERIFICATION
    kept = provider.headers
    verifier = nil.as(Verifier?)
    unless verification == :none
      verifier = provider.verifier || return NotFound.new
      kept += verifier.headers
    end
    store(P::PUNCH_PROVIDER, verification, verifier, provider.idempotency_key(request), request, kept, db, jobs)
  end

  # The stored key: the provider's, a hash of a key that does not parse,
  # or the body's hash without one. Not verified yet (*deferred*), a
  # delivery must not hold its key against the real one, so the body's
  # hash is part of it: a forged first delivery would otherwise make the
  # genuine one a conflict.
  private def self.key(raw_key : String?, fingerprint : Bytes, *, deferred : Bool) : String
    key = case parsed = raw_key.try { |text| IdempotencyKey.parse(text) }
          in IdempotencyKey then parsed.value
          in Invalid        then "sha256:#{Crypto::Fingerprint.of(raw_key.to_s).hexstring}"
          in Nil            then "sha256:#{fingerprint.hexstring}"
          end
    deferred ? "#{key}:#{fingerprint.hexstring}" : key
  end

  # Whether *name* has `MAX_UNVERIFIED` deliveries waiting for verification.
  private def self.backlogged?(db : Writer, name : String, wide : Trace::Span) : Bool
    waiting = db.query_one?("SELECT count(*) FROM punch_webhooks WHERE provider = ? AND state = 'received'", name,
      name: "Punch::Webhook.waiting", &.read(Int64)) || 0_i64
    return false if waiting < MAX_UNVERIFIED

    wide.set("punch.webhook.outcome", "backlogged") if wide.recording?
    true
  end

  private def self.store(name : String, verification : Symbol, verifier : Verifier?, raw_key : String?, request : RawRequest,
                         kept : Array(String), db : Writer, jobs : Jobs(Process)) : Received
    wide = Trace.event
    wide.set("punch.webhook.provider", name) if wide.recording?
    now = Time.utc
    if verification == :edge && verifier && !verifier.verify(request, now)
      wide.set("punch.webhook.outcome", "invalid_signature") if wide.recording?
      return InvalidSignature.new
    end
    fingerprint = Crypto::Fingerprint.of(request.body)

    return Backlogged.new if verification == :deferred && backlogged?(db, name, wide)

    key = key(raw_key, fingerprint, deferred: verification == :deferred)
    stored = Invocations.receive(db, name, key, fingerprint, request, kept, now, verification != :deferred)

    outcome = case stored
              in Int64
                jobs.enqueue(Process.new(stored, name))
                "received"
              in Invocations::Duplicate then "duplicate"
              in Invocations::Conflict  then "conflict"
              end
    if wide.recording?
      wide.set("punch.webhook.outcome", outcome)
      wide.set("punch.webhook.invocation", stored.is_a?(Int64) ? stored : stored.id)
    end

    stored.is_a?(Invocations::Conflict) ? IdempotencyKeyReused.new : nil
  end

  # Processes one stored invocation: Punch's job, enqueued by the endpoint
  # through the outbox. On its own queue, `webhooks`, at most four at a time
  # per provider.
  @[Punch::Job::Options(queue: "webhooks")]
  @[Punch::Job::Concurrency(4, by: :provider)]
  struct Process
    include Punch::Job

    getter invocation_id : Int64
    getter provider : String

    def initialize(@invocation_id, @provider)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      Webhook.dispatch(@provider, @invocation_id, job)
    end
  end

  # Processes the invocation *id* again, from its stored request: a
  # failed, unprocessable, or rejected one (`retry`), or a processed or
  # ignored one (`replay`), for the ops console. Moves it back and
  # enqueues `Process` through the outbox in *db*'s transaction. Returns
  # the provider, or `nil` when the invocation is not in such a state.
  # A replay runs the provider's `process` a second time for the same
  # delivery: only for a handler that is safe to repeat, or after a fix.
  def self.again(db : Writer, id : Int64, *, replay : Bool) : String?
    provider = Invocations.again(db, id, replay ? Invocations::REPLAY : Invocations::RETRY) || return
    Job::Outbox.add(db, Job::Queue.entry(Process.new(id, provider), Time.utc, traceparent: Trace.current.span_context.try(&.traceparent)))
    provider
  end

  # Runs the provider named *name* on invocation *id*.
  def self.dispatch(name : String, id : Int64, job : Job::Context) : Job::Result
    {% for provider in ::Punch::Webhook::Inbound.all_subclasses.reject(&.abstract?) %}
      return run({{ provider.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new, id, job) if name == {{ provider.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_PROVIDER
    {% end %}
    Job::Discard.new("no webhook provider #{name.inspect} in this binary")
  end

  # Verifies (if deferred), parses, and processes, each step recorded on
  # the invocation. A job runs at least once, so an invocation that is
  # finished already is left alone.
  def self.run(provider : P, id : Int64, job : Job::Context) : Job::Result forall P
    invocation = job.read { |db| Invocations.load(db, id) }
    wide = Trace.event
    if wide.recording?
      wide.set("punch.webhook.provider", P::PUNCH_PROVIDER)
      wide.set("punch.webhook.invocation", id)
      invocation.try { |found| wide.set("punch.webhook.lag_ms", (Time.utc - found.received_at).total_milliseconds.round(3)) if job.attempt == 1 }
    end

    case invocation
    in Nil then Job::Discard.new("webhook invocation #{id} is gone")
    in Invocation::Finished
      outcome("finished_before")
      nil
    in Invocation::Received
      verifier = provider.verifier || return Job::Retry.new("#{P::PUNCH_PROVIDER} has no verifier: its secret is missing from the credentials")

      # A verifier that raises refuses the delivery, rather than leaving it
      # waiting for good.
      checked = begin
        invocation.verify(verifier, Time.utc)
      rescue ex
        invocation.rejected("verifier_failed: #{ex.class}", Time.utc)
      end
      case checked
      in Invocation::Rejected
        job.write { |db| Invocations.save(db, checked).as(Nil) }
        outcome("rejected")
        Job::Discard.new("invalid signature")
      in Invocation::Verified then handle(provider, checked, job)
      end
    in Invocation::Verified then handle(provider, invocation, job)
    end
  end

  private def self.handle(provider : P, verified : Invocation::Verified, job : Job::Context) : Job::Result forall P
    case event = provider.parse(verified.request)
    when Ignored
      job.write { |db| Invocations.save(db, verified.ignored(event.reason, Time.utc)).as(Nil) }
      outcome("ignored")
      nil
    when Unprocessable
      job.write { |db| finish(provider, verified.unprocessable(event.reason, Time.utc), db).as(Nil) }
      Job::Discard.new(event.reason)
    else
      attempt(provider, verified, event, job)
    end
  end

  # One attempt at `process`, in one write transaction: the handler's
  # writes commit with the move to `processed`, or roll back, and the
  # invocation records why right after (`Lease#after_rollback`).
  private def self.attempt(provider : P, verified : Invocation::Verified, event : E, job : Job::Context) : Job::Result forall P, E
    result = begin
      job.write do |db|
        # Inside the write: a second run of the job (one released after a
        # stalled heartbeat) finds the first's end here, and leaves it.
        next unless Invocations.waiting?(db, verified.id)

        outcome = provider.punch_process(event, db)
        if outcome.is_a?(Processed)
          Invocations.save(db, verified.processed(Time.utc))
        else
          ended = ending(verified, outcome, job)
          db.lease.rollback_only = true
          db.lease.after_rollback = finishing(provider, ended)
        end
        outcome.as(Outcome)
      end
    rescue ex
      # A bug: retried with the job's backoff, the last attempt ends it.
      ended = job.last_attempt? ? verified.failed("#{ex.class}: #{ex.message}", Time.utc) : verified.retrying("#{ex.class}: #{ex.message}")
      job.write { |db| finish(provider, ended, db).as(Nil) }
      raise ex
    end
    outcome(case result
    in Nil                   then "finished_before"
    in Processed             then "processed"
    in Discarded             then "discarded"
    in Job::Retry            then job.last_attempt? ? "failed" : "retry"
    in Failed, Unprocessable then "failed"
    end)

    case result
    in Nil           then nil
    in Processed     then nil
    in Job::Retry    then result
    in Discarded     then Job::Discard.new(result.reason)
    in Failed        then Job::Discard.new(result.reason)
    in Unprocessable then Job::Discard.new(result.reason)
    end
  end

  private def self.ending(verified : Invocation::Verified, outcome : Job::Retry | Discarded | Failed | Unprocessable, job : Job::Context) : Ended
    case outcome
    in Job::Retry    then job.last_attempt? ? verified.failed(outcome.reason, Time.utc) : verified.retrying(outcome.reason)
    in Discarded     then verified.discarded(outcome.reason, Time.utc)
    in Failed        then verified.failed(outcome.reason, Time.utc)
    in Unprocessable then verified.unprocessable(outcome.reason, Time.utc)
    end
  end

  # How an attempt that did not process leaves the invocation.
  private alias Ended = Invocation::Verified | Invocation::Discarded | Invocation::Failed | Invocation::Unprocessable

  # What runs after the handler's rollback: *invocation* recorded.
  private def self.finishing(provider : P, invocation : Ended) : Proc(Writer, Nil) forall P
    ->(writer : Writer) { finish(provider, invocation, writer) }
  end

  # Saves *invocation*; one that ended failed or unprocessable publishes
  # `ProcessingFailed` and calls the provider's `on_failure`, in the
  # same transaction.
  private def self.finish(provider : P, invocation : Ended, db : Writer) : Nil forall P
    Invocations.save(db, invocation)

    case invocation
    in Invocation::Verified, Invocation::Discarded
    in Invocation::Failed, Invocation::Unprocessable
      # Punch's own handle: Punch publishes this event, not a Command.
      # ameba:disable Punch/EventsHandle
      Events(ProcessingFailed).for_transaction(db)
        .publish(ProcessingFailed.new(invocation.provider, invocation.id, invocation.state, invocation.error || ""))
      provider.on_failure(invocation, db)
    end
  end

  private def self.outcome(name : String) : Nil
    wide = Trace.event
    wide.set("punch.webhook.outcome", name) if wide.recording?
  end

  # Removes processed, ignored, and rejected invocations past the
  # retention (`PUNCH_WEBHOOK_RETENTION_DAYS`), every hour. Does nothing in
  # an app without providers.
  @[Punch::Job::Recurring(every: 1.hour)]
  struct Purge
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      return unless Webhook.used?

      removed = job.write { |db| Invocations.purge(db, Time.utc - Webhook.retention) }
      Trace.event.set("punch.webhook.purged", removed) if Trace.event.recording?
      nil
    end
  end
end
