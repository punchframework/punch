module Punch::Webhook
  # Declares an inbound webhook provider on a struct that subclasses
  # `Punch::Webhook::Inbound`:
  #
  # ```
  # @[Punch::Webhook::Provider("payments", verify: :edge, body_limit: 64 * 1024, rate_limit: 600)]
  # struct Billing::Payments::Provider < Punch::Webhook::Inbound
  # ```
  #
  # - The name (lowercase letters, digits, `_`, `-`) is the endpoint's
  #   path, `POST /webhooks/payments`, and the `provider` of its stored
  #   invocations.
  # - *verify*: `:edge` checks the signature before storing and answers
  #   401 to a bad one (the default); `:deferred` stores first and checks
  #   in the job, for providers that must get a 2xx quickly; `:none`
  #   checks nothing and needs no verifier: `punch webhooks` and `punch
  #   check` list such providers.
  # - *body_limit*: bytes, 256 KiB unless given. *rate_limit*: requests per
  #   minute and client address, 600 unless given.
  annotation Provider
  end

  # Whether a stored request is authentic. `HMAC` is Punch's; a provider
  # with another scheme writes its own.
  abstract struct Verifier
    # The headers it reads, kept with the stored request so the deferred
    # check and a later replay see them.
    abstract def headers : Array(String)

    # Whether *request* is authentic when it arrived at *now*.
    abstract def verify(request : RawRequest, now : Time) : Bool
  end

  # HMAC-SHA256 signatures by the Standard Webhooks scheme
  # (`Punch::Webhook::Signature`), with a timestamp tolerance against
  # replays and several secrets for a rotation: the current secret and the
  # one before it, while the provider switches. The header names can be
  # changed for providers that use the scheme under others.
  struct HMAC < Verifier
    def initialize(@secrets : Array(String), *, @tolerance : Time::Span = 5.minutes,
                   @id_header : String = Signature::ID_HEADER, @timestamp_header : String = Signature::TIMESTAMP_HEADER,
                   @signature_header : String = Signature::HEADER)
      raise ArgumentError.new("Punch::Webhook::HMAC needs at least one secret") if @secrets.empty?

      @secrets.each_with_index do |secret, index|
        bytes = Signature.key(secret) rescue raise ArgumentError.new("Punch::Webhook::HMAC: secret #{index + 1} starts with whsec_ but is not base64")
        if bytes.size < Signature::MIN_KEY_BYTES
          raise ArgumentError.new("Punch::Webhook::HMAC: secret #{index + 1} has #{bytes.size} bytes, fewer than #{Signature::MIN_KEY_BYTES}; a short or empty secret lets anyone sign")
        end
      end
    end

    def headers : Array(String)
      [@id_header, @timestamp_header, @signature_header]
    end

    def verify(request : RawRequest, now : Time) : Bool
      id = request.header(@id_header) || return false
      timestamp = request.header(@timestamp_header) || return false
      signature = request.header(@signature_header) || return false
      Signature.valid?(@secrets, id, timestamp, signature, request.body, now: now, tolerance: @tolerance)
    end

    def inspect(io : IO) : Nil
      io << "#<Punch::Webhook::HMAC " << @secrets.size << " secret(s)>"
    end
  end

  # What `process` returns: the event was handled, and its writes commit
  # with the invocation's move to `processed`.
  struct Processed
    def initialize
    end
  end

  # What `parse` returns for an event the app does not handle: the
  # invocation ends `ignored`, not unprocessed.
  struct Ignored
    getter reason : String

    def initialize(@reason : String)
    end
  end

  # The payload cannot be handled, now or later (`parse`, or `process` on
  # discovering it): the invocation ends `unprocessable`, the failure event
  # is published. Never retried.
  struct Unprocessable
    getter reason : String

    def initialize(@reason : String)
    end
  end

  # Processing failed for good, such as a payment for an invoice that does
  # not exist: the invocation ends `failed`, the failure event is
  # published. Never retried.
  struct Failed
    getter reason : String

    def initialize(@reason : String)
    end
  end

  # Nothing is left to do, and nobody needs to know, such as a payment
  # for an invoice that was deleted on purpose: the invocation ends
  # `discarded` with the reason, quietly. Never retried. `discard(reason)`
  # in `process` makes one.
  struct Discarded
    getter reason : String

    def initialize(@reason : String)
    end
  end

  # What `process` returns. `Punch::Job::Retry` (`retry(reason)`) tries
  # again with the job's backoff, and after the last attempt ends the
  # invocation as failed; an exception does the same and is recorded as a
  # bug. Anything but `Processed` rolls the handler's writes back.
  alias Outcome = Processed | Job::Retry | Discarded | Failed | Unprocessable

  # Published when an invocation ends failed or unprocessable, in the
  # transaction that records it: subscribe to alert someone.
  struct ProcessingFailed
    include Punch::Event

    getter provider : String
    getter invocation_id : Int64
    # `failed` or `unprocessable`.
    getter state : String
    getter reason : String

    def initialize(@provider, @invocation_id, @state, @reason)
    end
  end

  # The endpoint's answers besides 204 (accepted, or a repeat of an
  # accepted delivery).
  #
  # The signature is missing, wrong, or too old (edge verification).
  @[Punch::Status(401)]
  struct InvalidSignature
    include JSON::Serializable

    def initialize
    end
  end

  # The provider has no verifier, so the app takes none of its deliveries:
  # the credentials hold no secret.
  @[Punch::Status(404)]
  struct NotFound
    include JSON::Serializable

    def initialize
    end
  end

  # A delivery under a key the provider used before, with another payload.
  @[Punch::Status(409)]
  struct IdempotencyKeyReused
    include JSON::Serializable

    def initialize
    end
  end

  # What the receive endpoint answers.
  # Too many deliveries of the provider wait for verification
  # (`verify: :deferred`, `MAX_UNVERIFIED`): anyone can post one, so they
  # are not stored without bound. Providers retry a 503.
  @[Punch::Status(503)]
  struct Backlogged
    include JSON::Serializable

    def initialize
    end
  end

  # The most deliveries of one provider kept unverified at once.
  MAX_UNVERIFIED = 1000

  alias Received = InvalidSignature | NotFound | Backlogged | IdempotencyKeyReused?

  # An inbound webhook provider: how its deliveries are verified,
  # deduplicated, parsed, and processed.
  #
  # ```
  # @[Punch::Webhook::Provider("payments")]
  # struct Payments::Provider < Punch::Webhook::Inbound
  #   def verifier : Punch::Webhook::Verifier?
  #     secrets = Credentials.current.payments.webhook_secrets || return
  #     Punch::Webhook::HMAC.new(secrets)
  #   end
  #
  #   def parse(request : Punch::RawRequest) : Succeeded | Punch::Webhook::Ignored | Punch::Webhook::Unprocessable
  #     # parse request.body into one of the provider's typed events
  #   end
  #
  #   def process(event : Succeeded, db : Punch::Writer, events : Punch::Events(InvoicePaid)) : Punch::Webhook::Outcome
  #     # load, change, save; Punch::Webhook::Processed.new
  #   end
  # end
  # ```
  #
  # Punch adds the endpoint, `POST /webhooks/<name>` (the provider's
  # `Receive` Command): public, unlisted, rate-limited by client address,
  # with the provider's body limit. It stores the request and answers 204;
  # a job (`Punch::Webhook::Process`) processes it through the outbox.
  #
  # `process` takes the event, the writer, and optionally
  # `events : Punch::Events(...)` and `jobs : Punch::Jobs(...)`, like a
  # Command's `call`; one `process` per event type `parse` returns.
  abstract struct Inbound
    # Ends this processing attempt as an expected failure worth another,
    # after the job's backoff or after *after*, as `retry` does in a job.
    private def retry(reason : String, *, after : Time::Span? = nil) : Job::Retry
      Job::Retry.new(reason, after: after)
    end

    # Ends the invocation as `discarded`, quietly, never retried, as
    # `discard` does in a job.
    private def discard(reason : String) : Discarded
      Discarded.new(reason)
    end

    # The verifier, or `nil` when the app has no secret for the provider:
    # the endpoint then answers 404. Not called with `verify: :none`.
    def verifier : Verifier?
      nil
    end

    # The delivery's idempotency key: the Standard Webhooks `webhook-id`
    # unless overridden, such as with a field of the payload. Without one,
    # the key is the payload's hash, so an identical body is a repeat.
    def idempotency_key(request : RawRequest) : String?
      request.header(Signature::ID_HEADER)
    end

    # Headers kept with the stored request besides the verifier's.
    def headers : Array(String)
      ["content-type"]
    end

    # Called when an invocation ends failed or unprocessable, in the
    # transaction that records it, after `ProcessingFailed` is published.
    def on_failure(invocation : Invocation::Failed | Invocation::Unprocessable, db : Writer) : Nil
    end

    macro inherited
      macro finished
        \{% declared = @type.annotation(::Punch::Webhook::Provider) %}
        \{% unless declared %}
          \{% @type.raise "#{@type} is a webhook provider, so it has @[Punch::Webhook::Provider(\"name\")]: the name is its endpoint, /webhooks/name (lib/punch/docs/webhooks.md)." %}
        \{% end %}
        \{% name = declared[0] %}
        \{% unless name.is_a?(StringLiteral) && name =~ /\A[a-z][a-z0-9_-]{0,62}\z/ %}
          \{% declared.raise "@[Punch::Webhook::Provider] on #{@type}: the name is lowercase letters, digits, _ and -, such as \"payments\", not #{name}" %}
        \{% end %}
        \{% verify = declared[:verify] || :edge %}
        \{% unless verify == :edge || verify == :deferred || verify == :none %}
          \{% declared.raise "@[Punch::Webhook::Provider] on #{@type}: verify: is :edge, :deferred, or :none, not #{verify}" %}
        \{% end %}
        \{% if verify != :none && !@type.methods.any? { |method| method.name == "verifier" } %}
          \{% @type.raise "#{@type} verifies its deliveries (verify: #{verify}), so it defines `verifier : Punch::Webhook::Verifier?`, such as Punch::Webhook::HMAC.new(secrets); declare verify: :none for a provider that does not sign (lib/punch/docs/webhooks.md)." %}
        \{% end %}
        \{% unless @type.methods.any? { |method| method.name == "parse" } %}
          \{% @type.raise "#{@type} is a webhook provider, so it defines `parse(request : Punch::RawRequest)`, returning its event types, Punch::Webhook::Ignored, or Punch::Webhook::Unprocessable (lib/punch/docs/webhooks.md)." %}
        \{% end %}
        \{% processes = @type.methods.select { |method| method.name == "process" } %}
        \{% @type.raise "#{@type} is a webhook provider, so it defines `process(event : E, db : Punch::Writer) : Punch::Webhook::Outcome` for each event type E that `parse` returns (lib/punch/docs/webhooks.md)." if processes.empty? %}
        \{% extras = [] of ASTNode %}
        \{% for method in processes %}
          \{% unless method.args.size >= 2 && method.args[0].restriction && method.args[1].restriction && method.args[1].restriction.stringify.gsub(/^::/, "") == "Punch::Writer" %}
            \{% method.raise "#{@type}#process takes the event with its type and `db : Punch::Writer`, then optionally `events : Punch::Events(...)` and `jobs : Punch::Jobs(...)`." %}
          \{% end %}
          \{% for arg in method.args[2..-1] %}
            \{% kind = arg.restriction ? arg.restriction.stringify.gsub(/^::/, "").split("(")[0] : "" %}
            \{% unless kind == "Punch::Events" || kind == "Punch::Jobs" %}
              \{% arg.raise "#{@type}#process: `#{arg.name}` is neither `Punch::Events(...)` nor `Punch::Jobs(...)`, the only handles processing takes." %}
            \{% end %}
            \{% extras << arg.restriction %}
          \{% end %}

          # Runs `process` with the handles it asks for. :nodoc:
          def punch_process(event : \{{ method.args[0].restriction }}, db : ::Punch::Writer) : ::Punch::Webhook::Outcome
            process(event, db\{% for arg in method.args[2..-1] %}, \{{ arg.restriction }}.for_transaction(db)\{% end %})
          end
        \{% end %}

        # The name of `@[Punch::Webhook::Provider]`. :nodoc:
        PUNCH_PROVIDER = \{{ name }}
        # :edge, :deferred, or :none. :nodoc:
        PUNCH_VERIFICATION = \{{ verify }}
        # The handles `process` takes, for `punch events` and the outbox. :nodoc:
        alias PunchProcessExtras = Tuple(\{{ extras.splat }})

        # The endpoint of the provider: stores the request and answers 204,
        # or 401, 404, 409.
        @[::Punch::Public]
        @[::Punch::Unlisted]
        @[::Punch::Route("POST", \{{ "/webhooks/" + name }})]
        @[::Punch::RateLimit(\{{ declared[:rate_limit] || 600 }}, per: 1.minute, by: :ip, name: \{{ "webhooks." + name + ".ip" }})]
        @[::Punch::BodyLimit(\{{ declared[:body_limit] || 256 * 1024 }})]
        struct Receive < ::Punch::Command
          struct Input
            include ::Punch::Input
          end

          alias Output = ::Punch::Webhook::Received

          def call(input : Input, db : ::Punch::Writer, request : ::Punch::RawRequest,
                   jobs : ::Punch::Jobs(::Punch::Webhook::Process)) : Output
            ::Punch::Webhook.receive(\{{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new, request, db, jobs)
          end
        end
      end
    end
  end
end
