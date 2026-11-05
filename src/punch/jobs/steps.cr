require "json"

module Punch
  # Marks a method of a job that includes `Punch::Job::Stepped` as one of its
  # steps. Steps run in the order they are defined (docs/jobs.md, "Long
  # jobs: steps").
  annotation Job::Step
  end

  # Where a step stopped: `nil` on its first call, then the value it last
  # continued with. A step that takes one walks through work in pieces:
  #
  # ```
  # @[Punch::Job::Step]
  # def copy_rows(job : Punch::Job::Context, rows : Punch::Job::Cursor(Rows::ID)) : Punch::Job::StepResult
  #   batch = job.read { |db| Rows.after(db, rows.at, limit: 500) }
  #   return if batch.empty?
  #
  #   job.write do |db|
  #     copy(db, batch)
  #     rows.continue(batch.last.id) # saved with the copied rows
  #   end
  # end
  # ```
  #
  # *C* is any type a payload may hold: an ID, a time, a string such as a
  # provider's page token, or a record of several (`{created_at, id}` for
  # keyset order). It is stored as JSON and recorded in
  # `payloads.lock.json`, so it follows the payload rules across deploys.
  struct Job::Cursor(C)
    # Where the step stopped, `nil` on its first call.
    getter at : C?

    # :nodoc:
    def initialize(@at : C?)
    end

    # The cursor saved as *json*, or why it does not parse: the run is
    # then parked, like a payload that does not parse.
    # :nodoc:
    def self.parse(json : String?, type : String, step : String) : self | Job::Queue::Registry::Unreadable
      new(json.try { |text| Stored.from_json(C, text) })
    rescue ex : JSON::ParseException | JSON::SerializableError
      Job::Queue::Registry::Unreadable.new("#{type}##{step}: the saved cursor #{json} does not parse as #{C}: #{ex.message}")
    end

    # Calls the step again with *to* as its cursor: at once, or *in* a span
    # from now without holding a worker. Returned from inside `job.write`,
    # the cursor commits with that transaction; returned from the step, in
    # a transaction of its own.
    def continue(to : C, *, in delay : Time::Span? = nil) : Job::Continue
      Job::Continue.new(Stored.json(to), delay)
    end
  end

  # A step is not done: call it again, with a new cursor or the one it has
  # (`Punch::Job::Cursor#continue`, `again(in:)`). Not an attempt: a job
  # that continues never fails for it.
  struct Job::Continue
    # The new cursor as JSON, `nil` to keep the one saved.
    # :nodoc:
    getter cursor : String?
    # When given, the job goes back to the queue and the step is called
    # again after this span.
    getter delay : Time::Span?

    # :nodoc:
    def initialize(@cursor : String?, @delay : Time::Span?)
    end
  end

  # What a step returns: `nil` when it is done, `Punch::Job::Continue`
  # to be called again, or `Punch::Job::Retry` and `Punch::Job::Discard`
  # as from `perform`.
  alias Job::StepResult = Job::Continue | Job::Retry | Job::Discard?

  # Runs a job as named steps, each resumed where it stopped (docs/jobs.md,
  # "Long jobs: steps"). Progress is saved in `primary.db`, so a deploy, a
  # crash, or a retry continues from the last saved point instead of from
  # the beginning:
  #
  # ```
  # struct Imports::Run
  #   include Punch::Job
  #   include Punch::Job::Stepped
  #
  #   getter import_id : Imports::ID
  #
  #   def initialize(@import_id)
  #   end
  #
  #   @[Punch::Job::Step]
  #   def check_file(job : Punch::Job::Context) : Punch::Job::StepResult
  #     # ...
  #   end
  #
  #   @[Punch::Job::Step]
  #   def copy_rows(job : Punch::Job::Context, rows : Punch::Job::Cursor(Rows::ID)) : Punch::Job::StepResult
  #     # ...
  #   end
  # end
  # ```
  #
  # - Steps are methods marked `@[Punch::Job::Step]`, run in the order they
  #   are defined. Punch defines `perform`; the job does not.
  # - A step returns `nil` when done, `continue` to be called again, or
  #   `retry`/`discard` as `perform` does. A retry resumes the step where
  #   it stopped.
  # - Between calls the worker checks whether the process is stopping; if
  #   so the job goes back to the queue without counting an attempt.
  # - A step that finished, or a cursor that was saved, is never run
  #   again; work since the last save may be. Return the cursor from inside
  #   the `job.write` that does the work, and that work runs once.
  module Job::Stepped
    macro included
      macro finished
        \{% unless @type < ::Punch::Job %}
          \{% @type.raise "#{@type} includes Punch::Job::Stepped, so it is a job: include Punch::Job too (lib/punch/docs/jobs.md)." %}
        \{% end %}
        \{% steps = @type.methods.select(&.annotation(::Punch::Job::Step)) %}
        \{% if steps.empty? && !@type.abstract? %}
          \{% @type.raise "#{@type} includes Punch::Job::Stepped but marks no method @[Punch::Job::Step]; its steps run in the order they are defined (lib/punch/docs/jobs.md)." %}
        \{% end %}
        \{% if @type.methods.any? { |method| method.name == "perform" && !method.body.stringify.includes?("Punch::Job::Steps.run") } %}
          \{% @type.raise "#{@type} runs in steps, so Punch defines `perform`, which runs them in order: move its work into methods marked @[Punch::Job::Step] (lib/punch/docs/jobs.md)." %}
        \{% end %}
        \{% for step in steps %}
          \{% if steps.select { |other| other.name == step.name }.size > 1 %}
            \{% step.raise "#{@type}##{step.name} is defined twice as a step; a step's name is what its saved progress refers to, so each is defined once (lib/punch/docs/jobs.md)." %}
          \{% end %}
          \{% context = step.args[0] && step.args[0].restriction && step.args[0].restriction.resolve == ::Punch::Job::Context %}
          \{% cursor = step.args[1] && step.args[1].restriction && step.args[1].restriction.resolve? && step.args[1].restriction.resolve.name(generic_args: false) == "Punch::Job::Cursor" %}
          \{% unless context && (step.args.size == 1 || (step.args.size == 2 && cursor)) %}
            \{% step.raise "#{@type}##{step.name} is a step, so it takes `(job : Punch::Job::Context)`, or `(job : Punch::Job::Context, name : Punch::Job::Cursor(T))` to resume where it stopped, and returns Punch::Job::StepResult (lib/punch/docs/jobs.md)." %}
          \{% end %}

          # Calls the step with its saved cursor. Written here, where the
          # cursor's type resolves as the job wrote it.
          # :nodoc:
          def punch_step_\{{ step.name }}(context : ::Punch::Job::Context, cursor : ::String?) : ::Punch::Job::StepResult | ::Punch::Job::Queue::Registry::Unreadable
            \{% if step.args.size == 2 %}
              position = \{{ step.args[1].restriction }}.parse(cursor, \{{ @type.name.stringify }}, \{{ step.name.stringify }})
              return position if position.is_a?(::Punch::Job::Queue::Registry::Unreadable)

              ::Punch::Job::Steps.step_result(self.class, ::NamedTuple(\{{ step.name }}: ::Nil), \{{ step.name }}(context, position))
            \{% else %}
              ::Punch::Job::Steps.step_result(self.class, ::NamedTuple(\{{ step.name }}: ::Nil), \{{ step.name }}(context))
            \{% end %}
          end
        \{% end %}

        # The steps as the lock file records them (derivation build only).
        # :nodoc:
        def self.punch_steps_lock : ::JSON::Any
          ::JSON::Any.new([
            \{% for step in steps %}
              ::Punch::Job::Steps.lock_entry(self, \{{ step.name.stringify }}\{% if step.args.size == 2 %}, \{{ step.args[1].restriction }}\{% end %}),
            \{% end %}
          ] of ::JSON::Any)
        end
      end

      # Runs the steps in order, from where the job stopped (Punch defines
      # it; see `Punch::Job::Stepped`).
      def perform(job : ::Punch::Job::Context) : ::Punch::Job::Steps::Outcome
        ::Punch::Job::Steps.run(self, job)
      end
    end

    # Calls this step again after *delay*, with the cursor it has: for
    # waiting on another system without holding a worker. Not an attempt.
    # `return again(in: 5.minutes) unless export.ready?`
    private def again(*, in delay : Time::Span) : Job::Continue
      Job::Continue.new(nil, delay)
    end
  end

  # How jobs with steps run (`Punch::Job::Stepped`): the runner, the saved
  # progress, and what a run comes to. Not a mixin, so its names stay out
  # of the jobs.
  # :nodoc:
  module Job::Steps
    # The job goes back to the queue, due at *run_at*, its attempt not
    # counted: the worker is stopping, or a step waits.
    # :nodoc:
    struct Pause
      getter run_at : Time
      getter reason : String

      def initialize(@run_at : Time, @reason : String)
      end
    end

    # What a job with steps returns from `perform`.
    # :nodoc:
    alias Outcome = Job::Result | Pause | Job::Queue::Registry::Unreadable

    # Raised when `primary.db` lacks the progress table.
    class MissingTable < Exception
    end

    # One job's saved progress.
    record Saved, step : String?, cursor : String?, saves : Int64, updated_at : Time, finished_at : Time? do
      include JSON::Serializable

      # The cursor read as *type*, `nil` when none is saved.
      def cursor(type : T.class) : T? forall T
        cursor.try { |json| Stored.from_json(T, json) }
      end

      def finished? : Bool
        !finished_at.nil?
      end
    end

    # The state of one run of a job with steps, shared by its context and
    # the runner.
    # :nodoc:
    class Run
      getter key : String
      getter type : String
      getter saves = 0
      property step : String = ""
      property cursor : String? = nil
      # A cursor saved inside `job.write` this call, so the runner does
      # not save it again.
      property? saved_in_transaction = false

      def initialize(@key : String, @type : String, @stopping : Proc(Bool), @interrupt_every : Int32?)
      end

      # Whether to stop between calls: the process is stopping, or a spec
      # interrupts after every so many saves.
      def stop? : Bool
        return true if @stopping.call

        every = @interrupt_every
        !every.nil? && @saves > 0 && @saves % every == 0
      end

      def save(db : Writer, step : String?, cursor : String?, *, finished : Bool = false) : Nil
        Progress.save(db, @key, @type, step, cursor, Time.utc, finished)
        @saves += 1
      end

      # Saves what a `job.write` block returned.
      def save_in(db : Writer, continued : Job::Continue) : Nil
        @cursor = continued.cursor || @cursor
        save(db, @step, @cursor)
        @saved_in_transaction = true
      end
    end

    # Runs *job*'s steps from where it stopped. One small method per job
    # type, one block per step (compile-time budget).
    # :nodoc:
    def self.run(job : J, context : Job::Context) : Outcome forall J
      {% begin %}
        {% steps = J.methods.select(&.annotation(::Punch::Job::Step)) %}
        names = { {% for step in steps %} {{ step.name.stringify }}, {% end %} }
        run = context.steps_run || raise Job::Queue::Error.new("{{ J }} runs in steps, but its context has no run")
        saved = context.read { |db| Progress.load(db, run.key) }
        if saved
          return nil if saved.finished_at
          if (stopped = saved.step) && !names.includes?(stopped)
            return Job::Queue::Registry::Unreadable.new("{{ J }} stopped at step `#{stopped}`, which this binary does not have " \
                                                        "(it has #{names.join(", ")}); a binary that has it can resume the job")
          end
        end
        start = saved.try(&.step).try { |stopped| names.index!(stopped) } || 0
        cursor = saved.try(&.cursor)
        span = Trace.current
        span.set("punch.job.steps", names.size.to_i64) if span.recording?
        {% for step, index in steps %}
          if start <= {{ index }}
            cursor = nil if start < {{ index }}
            run.step = {{ step.name.stringify }}
            run.cursor = cursor
            span.set("punch.job.step", {{ step.name.stringify }}) if span.recording?
            loop do
              run.saved_in_transaction = false
              result = job.punch_step_{{ step.name }}(context, cursor)
              break result if result.is_a?(Job::Queue::Registry::Unreadable)

              case result
              in Job::Continue
                cursor = result.cursor || cursor
                context.write { |db| run.save(db, run.step, cursor) } unless run.saved_in_transaction?
                run.cursor = cursor
                if delay = result.delay
                  break Pause.new(Time.utc + delay, "waiting")
                end
                break Pause.new(Time.utc, "stopping") if run.stop?
              in Job::Retry
                break result
              in Job::Discard
                # A discarded run starts over if it is retried by hand.
                context.write { |db| Progress.delete(db, run.key) }
                break result
              in Nil
                {% if index + 1 < steps.size %}
                  context.write { |db| run.save(db, {{ steps[index + 1].name.stringify }}, nil) }
                  break Pause.new(Time.utc, "stopping") if run.stop?
                {% else %}
                  context.write { |db| run.save(db, nil, nil, finished: true) }
                {% end %}
                break nil
              end
            end.try { |ended| return ended }
          end
        {% end %}
        span.set("punch.job.step_saves", run.saves.to_i64) if span.recording?
        nil
      {% end %}
    end

    # Checks what a step returns.
    # :nodoc:
    def self.step_result(type : J.class, name : N.class, value : R) : Job::StepResult forall J, N, R
      {% raise "#{J}##{N.keys.first.id} returns #{R}; a step returns Punch::Job::StepResult: nil when done, a cursor's `continue` or `again(in:)` to be called again, `retry`, or `discard` (lib/punch/docs/jobs.md)." unless R <= ::Punch::Job::StepResult %}
      value
    end

    # The step names of every job with steps, in order, by type.
    class_getter names : Hash(String, Array(String)) { build_names }

    private def self.build_names : Hash(String, Array(String))
      names = {} of String => Array(String)
      {% for job in ::Punch::Job::Stepped.includers %}
        {% for type in [job] + job.all_subclasses %}
          {% unless type.abstract? %}
            names[{{ type.name.stringify }}] = [{% for step in type.methods.select(&.annotation(::Punch::Job::Step)) %} {{ step.name.stringify }}, {% end %}] of String
          {% end %}
        {% end %}
      {% end %}
      names
    end

    # One step as the lock file records it: its name and its cursor's
    # schema. Called only in the derivation build.
    # :nodoc:
    def self.lock_entry(job : J.class, name : String) : JSON::Any forall J
      JSON::Any.new({"name" => JSON::Any.new(name)})
    end

    # :nodoc:
    def self.lock_entry(job : J.class, name : String, cursor : Job::Cursor(C).class) : JSON::Any forall J, C
      JSON::Any.new({"name" => JSON::Any.new(name), "cursor" => cursor_schema(J, C)})
    end

    # :nodoc:
    def self.cursor_schema(job : J.class, type : C.class) : JSON::Any forall J, C
      {% for member in C.union_types %}
        {% for held in [member] + member.type_vars + member.instance_vars.map(&.type) %}
          {% if held.is_a?(TypeNode) && held.class.methods.any? { |method| method.name == "read" && method.args.size == 1 && method.args[0].restriction && method.args[0].restriction.stringify.ends_with?("Database::Row") } %}
            {% raise "a cursor of #{J} holds #{held}, a whole row. Store its ID, or the values the step orders by (lib/punch/docs/jobs.md)." %}
          {% end %}
        {% end %}
      {% end %}
      registry = JSONSchema::Registry.new(payloads: true)
      reference = registry.schema(C)
      definitions = registry.definitions
      return reference if definitions.empty?

      JSONSchema.object(reference.as_h.merge({"$defs" => JSON::Any.new(definitions)}))
    end

    # The progress table in `primary.db`: one row per run of a job with
    # steps, written in the step's transactions.
    # :nodoc:
    module Progress
      TABLE = "punch_job_progress"

      COLUMNS = {
        "key" => "TEXT", "type" => "TEXT", "step" => "TEXT", "cursor" => "TEXT", "saves" => "INTEGER",
        "updated_at" => "INTEGER", "finished_at" => "INTEGER",
      }

      # The table as a migration: `punch db:migration --punch steps`.
      def self.sql : String
        <<-SQL
          -- Progress of jobs that run in steps (lib/punch/docs/jobs.md, "Long jobs: steps"),
          -- written in the steps' own transactions. The columns are Punch's.
          CREATE TABLE punch_job_progress (
            key         TEXT    PRIMARY KEY,
            type        TEXT    NOT NULL,
            step        TEXT,
            cursor      TEXT,
            saves       INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL,
            finished_at INTEGER
          ) STRICT, WITHOUT ROWID;

          CREATE INDEX punch_job_progress_finished ON punch_job_progress (finished_at) WHERE finished_at IS NOT NULL;

          SQL
      end

      # What is missing or of another type, one line each.
      def self.problems(database : Database) : Array(String)
        found = database.read do |db|
          db.query_all("SELECT name, type FROM pragma_table_info('punch_job_progress')", name: "Punch::Job::Steps::Progress.columns") do |row|
            {row.read(String), row.read(String).upcase}
          end.to_h
        end
        return ["table punch_job_progress is missing; add it with a migration: punch db:migration --punch steps (lib/punch/docs/jobs.md)"] if found.empty?

        COLUMNS.compact_map do |column, type|
          if actual = found[column]?
            "punch_job_progress.#{column} is #{actual}, Punch needs #{type}" unless actual == type
          else
            "punch_job_progress.#{column} is missing (lib/punch/docs/jobs.md)"
          end
        end
      end

      def self.present?(database : Database) : Bool
        database.read { |db| !!db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_job_progress'", &.read(Int64)) }
      end

      def self.load(db : Reader, key : String) : Saved?
        db.query_one?("SELECT step, cursor, saves, updated_at, finished_at FROM punch_job_progress WHERE key = ?", key,
          name: "Punch::Job::Steps::Progress.load") do |row|
          Saved.new(row.read(String?), row.read(String?), row.read(Int64), Time.unix_ms(row.read(Int64)), row.read(Int64?).try { |millis| Time.unix_ms(millis) })
        end
      rescue ex : Database::Error
        raise missing(ex)
      end

      def self.save(db : Writer, key : String, type : String, step : String?, cursor : String?, now : Time, finished : Bool) : Nil
        db.exec(<<-SQL, key, type, step, cursor, now.to_unix_ms, finished ? now.to_unix_ms : nil, name: "Punch::Job::Steps::Progress.save")
          INSERT INTO punch_job_progress (key, type, step, cursor, saves, updated_at, finished_at) VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6)
          ON CONFLICT (key) DO UPDATE SET step = ?3, cursor = ?4, saves = saves + 1, updated_at = ?5, finished_at = ?6
          SQL

      rescue ex : Database::Error
        raise missing(ex)
      end

      def self.delete(db : Writer, key : String) : Nil
        db.exec("DELETE FROM punch_job_progress WHERE key = ?", key, name: "Punch::Job::Steps::Progress.delete")
      end

      # Removes the progress of runs that finished before *before*. Nothing
      # without the table (Punch's own specs; `serve` refuses to start
      # without it).
      def self.purge(db : Writer, before : Time) : Int64
        return 0_i64 unless db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_job_progress'", name: "Punch::Job::Steps::Progress.present", &.read(Int64))

        db.exec("DELETE FROM punch_job_progress WHERE finished_at < ?", before.to_unix_ms, name: "Punch::Job::Steps::Progress.purge").changes
      end

      private def self.missing(error : Database::Error) : Exception
        return error unless (error.message || "").includes?("no such table: punch_job_progress")

        MissingTable.new("primary.db has no punch_job_progress table, which jobs with steps save their progress in; " \
                         "add it with a migration: punch db:migration --punch steps (lib/punch/docs/jobs.md)")
      end
    end
  end
end
