require "log"

module Punch
  # A domain event: an immutable struct that says what happened, in the past
  # tense, with the IDs and small values a subscriber needs.
  #
  # ```
  # struct Billing::InvoiceSent
  #   include Punch::Event
  #
  #   getter invoice_id : Invoices::ID
  #   getter customer_id : Customers::ID
  #
  #   def initialize(@invoice_id, @customer_id)
  #   end
  # end
  # ```
  #
  # A Command publishes it through the handle its `call` asks for,
  # `events : Punch::Events(InvoiceSent)`; subscribers include
  # `Punch::Subscriber(InvoiceSent)` (docs/events.md).
  module Event
    macro included
      # Deferred subscribers get the event as a job payload.
      include ::JSON::Serializable

      {% unless @type.struct? %}
        {% @type.raise "#{@type} includes Punch::Event, so it must be a struct: an event is an immutable value (lib/punch/docs/events.md). A marker module that several events share, for a subscriber to listen to, includes nothing; the events include it." %}
      {% end %}
      macro finished
        \{% unless @type.abstract? || @type.methods.any? { |method| method.name == "initialize" && !method.args.any? { |arg| arg.name.stringify == "__pull_for_json_serializable" } } %}
          \{% @type.raise "#{@type} is an event, so it defines `initialize`, also when it has no fields: JSON::Serializable, which deferred subscribers read it with, replaces the default one. Write it as a record (`record #{@type.name.split("::").last.id} do … end`, with its fields after the name), which defines it, or add `def initialize; end` (lib/punch/docs/events.md)." %}
        \{% end %}
        ::Punch::Payloads.check_strict(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        \{% unless @type.abstract? %}
          ::Punch::Payloads.reader(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        \{% end %}
        \{% for method in @type.methods %}
          \{% name = method.name.stringify %}
          \{% if name.ends_with?("=") && !%w(== != === <= >= =~).includes?(name) %}
            \{% method.raise "#{@type}##{method.name}: an event is immutable, so it has no setters (lib/punch/docs/events.md). Publish a new event instead." %}
          \{% end %}
        \{% end %}
      end
    end
  end

  # Included by a type that reacts to events of type *E*: an event struct,
  # an abstract event, or a module that events include. Include it once per
  # type listened to.
  #
  # ```
  # struct Billing::Customers::ForgetStatement
  #   include Punch::Subscriber(Billing::InvoiceSent)
  #
  #   def call(event : Billing::InvoiceSent) : Nil
  #     STATEMENTS.delete(event.customer_id)
  #   end
  # end
  # ```
  #
  # After-commit subscribers define `call(event)`; inline ones
  # (`@[Punch::Subscriber::Delivery(:inline)]`) define `call(event, db : Punch::Writer)`;
  # deferred ones (`@[Punch::Subscriber::Delivery(:deferred)]`) define
  # `call(event, job : Punch::Job::Context) : Punch::Job::Result`.
  # A subscriber is made with `new` for every event, so it keeps no state.
  module Subscriber(E)
    # Ends a deferred subscriber's run as done but not as hoped, with
    # *reason*, never retried, as `discard` does in a job.
    private def discard(reason : String) : Job::Discard
      Job::Discard.new(reason)
    end

    # Ends a deferred subscriber's run as an expected failure worth another
    # attempt, as `retry` does in a job.
    private def retry(reason : String, *, after : Time::Span? = nil) : Job::Retry
      Job::Retry.new(reason, after: after)
    end

    # How a subscriber is delivered:
    # `@[Punch::Subscriber::Delivery(:inline)]` runs it inside the
    # publishing Command's transaction, with its `Writer`; without the
    # annotation it runs once the transaction has committed
    # (`:after_commit`); `:deferred` runs it as a durable job, written to
    # the outbox in the transaction.
    annotation Delivery
    end

    # Makes an after-commit subscriber forget cache entries: Punch writes
    # its `call`, so `punch events` can show which event clears which store.
    #
    # ```
    # @[Punch::Subscriber::Forget(STATEMENTS, key: customer_id)]
    # struct Billing::Customers::ForgetStatement
    #   include Punch::Subscriber(Billing::BalanceChanged)
    # end
    # ```
    #
    # `key:` names the event's getter for the key to delete: a key of the
    # store, a nilable one, or an array of keys. Without `key:`, the whole
    # store is cleared.
    annotation Forget
    end

    macro included
      macro finished
        \{% events = [] of TypeNode %}
        \{% for type in ::Punch::Event.includers %}
          \{% events << type unless type.abstract? %}
          \{% for subclass in type.all_subclasses %}
            \{% events << subclass unless subclass.abstract? %}
          \{% end %}
        \{% end %}
        \{% for ancestor in @type.ancestors.select { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" } %}
          \{% listened = ancestor.type_vars[0] %}
          \{% unless events.any? { |event| event <= listened } %}
            \{% @type.raise "#{@type} subscribes to #{listened}, which is no event and which no event includes or inherits. An event is a struct that includes Punch::Event (lib/punch/docs/events.md)." %}
          \{% end %}
        \{% end %}
        \{% delivery = @type.annotation(::Punch::Subscriber::Delivery) %}
        \{% mode = delivery ? delivery[0] : :after_commit %}
        \{% forget = @type.annotation(::Punch::Subscriber::Forget) %}
        \{% if forget %}
          \{% if delivery %}
            \{% delivery.raise "#{@type} forgets cache entries, which happens after commit: drop @[Punch::Subscriber::Delivery] (lib/punch/docs/cache.md)." %}
          \{% end %}
          \{% if forget.args.size != 1 || forget.named_args.keys.any? { |name| name != "key".id } %}
            \{% forget.raise "@[Punch::Subscriber::Forget] on #{@type} takes one cache store and an optional key: the event's getter, as in @[Punch::Subscriber::Forget(STATEMENTS, key: customer_id)] (lib/punch/docs/cache.md)." %}
          \{% end %}
          \{% if @type.methods.any? { |method| method.name == "call" } %}
            \{% @type.raise "#{@type} has @[Punch::Subscriber::Forget], so Punch writes its `call`: remove the one defined here, or the annotation (lib/punch/docs/cache.md)." %}
          \{% end %}
          \{% if key = forget[:key] %}
            \{% for ancestor in @type.ancestors.select { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" } %}
              \{% listened = ancestor.type_vars[0] %}
              \{% unless ([listened] + listened.ancestors).any? { |type| type.has_method?(key.id) } %}
                \{% forget.raise "@[Punch::Subscriber::Forget] on #{@type}: #{listened} has no `#{key.id}` to take the key from (lib/punch/docs/cache.md)." %}
              \{% end %}
            \{% end %}
          \{% end %}

          # The store this subscriber forgets entries of, for `punch events`.
          def self.punch_forgets : ::Punch::Caches::Store
            \{{ forget[0] }}
          end

          def call(event) : Nil
            \{% if key = forget[:key] %}
              ::Punch::Caches.forget(\{{ forget[0] }}, event.\{{ key.id }}, self.class)
            \{% else %}
              ::Punch::Caches.forget_all(\{{ forget[0] }})
            \{% end %}
          end
        \{% end %}
        \{% if mode != :inline && mode != :after_commit && mode != :deferred %}
          \{% delivery.raise "@[Punch::Subscriber::Delivery] on #{@type} takes :inline, :after_commit, or :deferred, not #{mode}" %}
        \{% end %}
        \{% if mode != :deferred && (@type.annotation(::Punch::Job::Options) || @type.annotation(::Punch::Job::Concurrency)) %}
          \{% @type.raise "#{@type} has job options, but only a deferred subscriber runs as a job: @[Punch::Subscriber::Delivery(:deferred)] (lib/punch/docs/events.md)." %}
        \{% end %}
        ::Punch::Job::Queue.check_options(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, \{{ @type.name.stringify }})
        \{% calls = @type.methods.select { |method| method.name == "call" } %}
        \{% if mode == :deferred %}
          \{% unless calls.any? { |method| method.args.size == 2 && method.args[1].restriction && method.args[1].restriction.resolve == ::Punch::Job::Context } %}
            \{% @type.raise "#{@type} is deferred, so it defines `call(event, job : Punch::Job::Context) : Punch::Job::Result`: it runs as a job, after the commit (lib/punch/docs/events.md)." %}
          \{% end %}
        \{% elsif mode == :inline %}
          \{% unless calls.any? { |method| method.args.size == 2 && method.args[1].restriction && method.args[1].restriction.resolve == ::Punch::Writer } %}
            \{% @type.raise "#{@type} is delivered inline, so it defines `call(event, db : Punch::Writer) : Nil`: it runs inside the publishing Command's transaction (lib/punch/docs/events.md)." %}
          \{% end %}
        \{% elsif !forget %}
          \{% unless calls.any? { |method| method.args.size == 1 } %}
            \{% @type.raise "#{@type} is delivered after commit, so it defines `call(event) : Nil`, with no database handle: the transaction is over. Use @[Punch::Subscriber::Delivery(:inline)] to write in it (lib/punch/docs/events.md)." %}
          \{% end %}
        \{% end %}
      end
    end
  end

  # The events a Command may publish, asked for in its `call`:
  # `events : Punch::Events(InvoiceSent | InvoiceVoided)`. The type is the
  # declaration `punch events` prints; publishing anything else does not
  # compile.
  #
  # A published event is delivered to inline subscribers at once, inside
  # the transaction, and to the others once it has committed. If the
  # Command fails (its writes roll back) or raises, nothing is delivered
  # after commit.
  struct Events(T)
    private def initialize(@writer : Writer)
    end

    # The handle for one write transaction. Only the router, which reads
    # the type from `call`, and `Punch::Spec.events` make one.
    # :nodoc:
    def self.for_transaction(writer : Writer) : self
      new(writer)
    end

    # Publishes *event*: runs its inline subscribers now, in this
    # transaction, and the others after it commits. An event the handle's
    # type does not list matches no overload, which the compiler reports
    # where it is published (add the event to the type in `call`,
    # docs/events.md).
    def publish(event : T) : Nil
      Subscribers.publish(event, @writer)
    end
  end

  # Delivery and the subscriber graph, resolved at compile time.
  # :nodoc:
  module Subscribers
    Log = ::Log.for("punch.events")

    # Every concrete event and its subscribers, for `punch events`.
    # *forgets* pairs each subscriber annotated `@[Punch::Subscriber::Forget]` with the
    # name of the cache store it forgets entries of.
    record Node, event : String, publishers : Array(String), subscribers : Array({String, String}),
      forgets : Array({String, String}) = [] of {String, String}

    # Runs *event*'s inline subscribers inside *writer*'s transaction and
    # leaves the after-commit delivery on it.
    def self.publish(event : E, writer : Writer) : Nil forall E
      {% begin %}
        {% subscribers = ::Punch::Subscriber.includers.uniq.select { |subscriber| subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && E <= ancestor.type_vars[0] } }.sort_by(&.name.stringify) %}
        {% inline = subscribers.select { |subscriber| (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :inline } %}
        {% deferred = subscribers.select { |subscriber| (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred } %}
        {% after = subscribers.reject { |subscriber| inline.includes?(subscriber) || deferred.includes?(subscriber) } %}
        span = Subscribers.published({{ E.stringify }})
        begin
          {% unless inline.empty? %}
            Trace.with(span) do
              {% for subscriber in inline %}
                Subscribers.inline({{ subscriber.stringify }}) { {{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new.call(event, writer) }
              {% end %}
            end
          {% end %}
          {% for subscriber in deferred %}
            Job::Outbox.add(writer, Job::Queue.deferred_entry({{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, event, Time.utc))
          {% end %}
          {% live = ::Punch::Page.all_subclasses.any? { |page| page.has_constant?("PunchLiveEvents") && parse_type("::#{page}::PunchLiveEvents").resolve.type_vars.any? { |listened| E <= listened } } %}
          writer.lease.after_commit(->{
            Subscribers.record(event, {{ E.stringify }})
            {% for subscriber in after %}
              Subscribers.after_commit({{ subscriber.stringify }}, {{ E.stringify }}) { {{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new.call(event) }
            {% end %}
            {% if live %}
              # To the pages people have open (docs/views.md).
              Live.publish(event)
            {% end %}
            nil
          })
        rescue ex
          span.error(ex)
          raise ex
        ensure
          span.finish
        end
      {% end %}
    end

    # The span of one publish, below the transaction's, counted on the
    # wide event.
    def self.published(event : String) : Trace::Span
      span = Trace.current.child("publish #{event}")
      if span.recording?
        span.set("punch.event", event)
      end
      wide = Trace.event
      wide.add("punch.events.published", 1) if wide.recording?
      span
    end

    # Runs one inline subscriber in its span. An exception fails the
    # Command: its transaction rolls back.
    def self.inline(subscriber : String, &) : Nil
      Trace.current.span(subscriber) do |span|
        span.set("punch.subscriber", subscriber)
        span.set("punch.delivery", "inline")
        yield
      end
    end

    # Runs one after-commit subscriber in its span. The data is committed,
    # so an exception cannot undo anything: it is logged, marks the span
    # failed, and is counted as `punch.events.failed`; the other
    # subscribers and the response go on.
    def self.after_commit(subscriber : String, event : String, &) : Nil
      span = Trace.current.child(subscriber)
      span.set("punch.subscriber", subscriber)
      span.set("punch.delivery", "after_commit")
      begin
        Trace.with(span) { yield }
      rescue ex
        span.error(ex)
        wide = Trace.event
        if wide.recording?
          wide.add("punch.events.failed", 1)
          wide.record_exception(ex, subscriber)
        end
        Log.error(exception: ex) { "#{subscriber} failed on #{event}" }
      ensure
        span.finish
      end
    end

    # Names the committed *event* on the wide event (`punch.events`, for
    # the ops sink) and hands it to `Punch::Spec.published`, if it records
    # in this fiber.
    def self.record(event : Event, name : String) : Nil
      wide = Trace.event
      wide.append("punch.events", name) if wide.recording?
      Fiber.current.punch_published.try(&.<<(event))
    end

    # The graph `punch events` prints: every concrete event, the operations
    # whose `call` may publish it, and its subscribers with their delivery.
    def self.graph : Array(Node)
      {% begin %}
        {% events = [] of TypeNode %}
        {% for type in ::Punch::Event.includers %}
          {% events << type unless type.abstract? %}
          {% for subclass in type.all_subclasses %}
            {% events << subclass unless subclass.abstract? %}
          {% end %}
        {% end %}
        {% operations = ::Punch::Operation.all_subclasses.reject(&.abstract?).select(&.has_constant?("PunchCallExtras")) %}
        {% providers = ::Punch::Webhook::Inbound.all_subclasses.reject(&.abstract?) %}
        {% subscribers = ::Punch::Subscriber.includers.uniq.sort_by(&.name.stringify) %}
        {% if providers.empty? %}
          {% events = events.reject { |event| event == ::Punch::Webhook::ProcessingFailed } %}
        {% end %}
        {% if ::Punch::Role.includers.empty? %}
          {% events = events.reject { |event| event == ::Punch::Roles::Assigned || event == ::Punch::Roles::Revoked } %}
        {% end %}
        [
          {% for event in events.sort_by(&.name.stringify) %}
            Node.new({{ event.stringify }},
              [
                {% for operation in operations.sort_by(&.name.stringify) %}
                  {% if parse_type("::#{operation}::PunchCallExtras").resolve.type_vars.any? { |type| type.name(generic_args: false) == "Punch::Events" && event <= type.type_vars[0] } %}
                    {{ operation.stringify }},
                  {% end %}
                {% end %}
                # Webhook processing: a provider's `process`, and Punch's
                # job for a final failure.
                {% for provider in providers.sort_by(&.name.stringify) %}
                  {% if parse_type("::#{provider}::PunchProcessExtras").resolve.type_vars.any? { |type| type.name(generic_args: false) == "Punch::Events" && event <= type.type_vars[0] } %}
                    {{ "#{provider}#process" }},
                  {% end %}
                {% end %}
                {% if event == ::Punch::Webhook::ProcessingFailed %}
                  "Punch::Webhook::Process",
                {% end %}
                # Notifications.
                {% if event == ::Punch::Ops::ErrorOccurred || event == ::Punch::Ops::JobsFailing || event == ::Punch::Ops::BackupStale %}
                  "Punch::Ops::Notify",
                {% end %}
              ] of String,
              [
                {% for subscriber in subscribers %}
                  {% if subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                    {% delivery = subscriber.annotation(::Punch::Subscriber::Delivery) %}
                    { {{ subscriber.stringify }}, {{ delivery ? delivery[0].id.stringify : "after_commit" }} },
                  {% end %}
                {% end %}
              ] of {String, String},
              [
                {% for subscriber in subscribers %}
                  {% if subscriber.annotation(::Punch::Subscriber::Forget) && subscriber.ancestors.any? { |ancestor| ancestor.name(generic_args: false) == "Punch::Subscriber" && event <= ancestor.type_vars[0] } %}
                    { {{ subscriber.stringify }}, {{ subscriber.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.punch_forgets.name },
                  {% end %}
                {% end %}
              ] of {String, String}),
          {% end %}
        ] of Node
      {% end %}
    end
  end
end

class Fiber
  # Where `Punch::Spec.published` collects the events delivered in this
  # fiber. :nodoc:
  property punch_published : Array(Punch::Event)?
end

require "./live"
