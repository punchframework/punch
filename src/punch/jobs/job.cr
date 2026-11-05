require "json"

module Punch
  # A background job: a struct whose fields are its payload, stored as JSON
  # in `queue.db` and parsed again when a worker claims it, and a `perform`
  # that does the work.
  #
  # ```
  # struct Billing::Invoices::Remind
  #   include Punch::Job
  #
  #   getter invoice_id : Invoices::ID
  #
  #   def initialize(@invoice_id)
  #   end
  #
  #   def perform(job : Punch::Job::Context) : Punch::Job::Result
  #     invoice = job.read { |db| Invoices::Table.find(db, invoice_id) }
  #     return discard("invoice deleted") unless invoice
  #     # ...
  #   end
  # end
  # ```
  #
  # - Keep the payload to IDs and small values: the job reads the rest
  #   when it runs, so it sees the data as it is then.
  # - `perform` returns `nil` when done, `Punch::Job::Retry` for an expected
  #   failure worth another attempt, or `Punch::Job::Discard` when there is
  #   nothing left to do; `retry(reason)` and `discard(reason)` make them. An exception is retried too, and recorded as a
  #   bug. Jobs run at least once: after a crash or a restore a job can
  #   run again, so make it safe to repeat.
  # - Options by annotation: `@[Punch::Job::Options(queue: "mail", attempts: 5, priority: 10)]`.
  # - The payload's shape is recorded in `payloads.lock.json`; `punch
  #   check` fails on a change older or newer binaries cannot read. A
  #   breaking change raises the version: `@[Punch::Payloads::Version(2,
  #   from: {1 => V1})]`, with the old shape kept as a frozen type.
  module Job
    macro included
      include ::JSON::Serializable

      {% unless @type.struct? %}
        {% @type.raise "#{@type} includes Punch::Job, so it must be a struct: its fields are the payload, a value stored in queue.db (lib/punch/docs/jobs.md)." %}
      {% end %}
      macro finished
        \{% if !(@type < ::Punch::Job::Stepped) && (marked = @type.methods.find(&.annotation(::Punch::Job::Step))) %}
          \{% marked.raise "#{@type}##{marked.name} is marked @[Punch::Job::Step], but #{@type} does not run in steps: include Punch::Job::Stepped (lib/punch/docs/jobs.md)." %}
        \{% end %}
        \{% performs = @type.methods.select { |method| method.name == "perform" } %}
        \{% unless @type.abstract? || @type.methods.any? { |method| method.name == "initialize" && !method.args.any? { |arg| arg.name.stringify == "__pull_for_json_serializable" } } %}
          \{% @type.raise "#{@type} is a job, so it defines `initialize`, also when it has no fields: JSON::Serializable, which reads its payload, replaces the default one. Write it as a record (`record #{@type.name.split("::").last.id} do … end`, with its fields after the name), which defines it, or add `def initialize; end` (lib/punch/docs/jobs.md)." %}
        \{% end %}
        \{% unless @type.abstract? || performs.any? { |method| method.args.size == 1 && method.args[0].restriction && method.args[0].restriction.resolve == ::Punch::Job::Context } %}
          \{% @type.raise "#{@type} is a job, so it defines `perform(job : Punch::Job::Context) : Punch::Job::Result` (lib/punch/docs/jobs.md)." %}
        \{% end %}
        ::Punch::Job::Queue.check_options(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, \{{ @type.name.stringify }})
        ::Punch::Payloads.check_strict(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        \{% unless @type.abstract? %}
          ::Punch::Payloads.reader(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        \{% end %}
      end
    end

    # Ends the run as done but not as hoped, with *reason*, never retried:
    # `return discard("invoice #{invoice_id} is paid") if invoice.paid?`.
    private def discard(reason : String) : Discard
      Discard.new(reason)
    end

    # Ends the run as an expected failure worth another attempt, after the
    # backoff or after *after*: `return retry("provider answered 503") if
    # response.status.service_unavailable?`.
    private def retry(reason : String, *, after : Time::Span? = nil) : Retry
      Retry.new(reason, after: after)
    end
  end

  # Where and how often a job (or a deferred subscriber) runs:
  #
  # ```
  # @[Punch::Job::Options(queue: "mail", attempts: 5, priority: 10)]
  # ```
  #
  # - *queue*: a name of lowercase letters, digits, and `_`; `default`
  #   unless given. Queues can be paused (`punch jobs:pause`).
  # - *attempts*: runs in all before the job counts as failed, 1 to 100;
  #   10 unless given, which spreads retries over about 17 hours.
  # - *priority*: higher runs first among due jobs, -100 to 100; 0 unless
  #   given.
  annotation Job::Options
  end

  # The job is done, but not as hoped, and another attempt would not
  # change that: the invoice it was about was deleted, the address
  # bounced for good. Recorded with the reason; never retried.
  struct Job::Discard
    getter reason : String

    def initialize(@reason : String)
    end
  end

  # An expected failure worth another attempt, such as a provider
  # answering 503: counted as an attempt and retried after the job's
  # backoff, or after *after* when given. After the last attempt the job
  # counts as failed.
  struct Job::Retry
    getter reason : String
    getter after : Time::Span?

    def initialize(@reason : String, *, @after : Time::Span? = nil)
    end
  end

  # What `perform` returns: `nil` when done.
  alias Job::Result = Job::Retry | Job::Discard?

  # What a running job may use: the primary database, one transaction at
  # a time, its own ID and attempt, and the queue to enqueue follow-ups.
  #
  # A job is not an operation: it may call other systems, so it holds no
  # transaction while it runs. It reads and writes in short transactions
  # of its own.
  struct Job::Context
    # The job's row in `queue.db`.
    getter id : Int64
    # 1 on the first run.
    getter attempt : Int32
    # Runs in all before the job counts as failed.
    getter attempts : Int32
    getter queue_name : String
    # Stable across attempts and retries: pass it as an idempotency key
    # to providers that take one.
    getter key : String

    # The run of a job with steps (`Punch::Job::Stepped`), `nil` for others.
    # :nodoc:
    getter steps_run : Job::Steps::Run?

    # :nodoc:
    def initialize(@database : Database, @queue : Job::Queue, @id : Int64, @attempt : Int32, @attempts : Int32,
                   @queue_name : String, @key : String, @steps_run : Job::Steps::Run? = nil)
    end

    # The queue itself, for Punch's own jobs (`Job::Queue::Purge`).
    # :nodoc:
    def store : Job::Queue
      @queue
    end

    # Whether this is the last attempt: a `Job::Retry` now fails the job.
    def last_attempt? : Bool
      @attempt >= @attempts
    end

    # Runs *block* in a read transaction on the primary database.
    def read(& : Reader -> T) : T forall T
      @database.read { |db| yield db }
    end

    # Runs *block* in a write transaction on the primary database. It
    # commits when the block returns and rolls back when it raises.
    #
    # In a job with steps, a `Punch::Job::Continue` the block returns is
    # saved in this transaction, so the cursor commits with the work.
    def write(&block : Writer -> T) : T forall T
      @database.write do |db|
        value = block.call(db)
        if value.is_a?(Job::Continue) && (run = @steps_run)
          run.save_in(db, value)
        end
        value
      end
    end

    # Enqueues a follow-up job directly into `queue.db`. Call it after the
    # write it follows from has committed, never inside `write`: there is
    # no outbox for jobs (the known gap of a restore).
    def enqueue(job : J, *, at : Time? = nil, in delay : Time::Span? = nil) : Int64? forall J
      @queue.enqueue(job, at: at, in: delay)
    end
  end
end
