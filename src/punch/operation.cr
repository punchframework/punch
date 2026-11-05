module Punch
  # Overrides the derived route: `@[Punch::Route("POST", "/webhooks/:provider")]`.
  # The `:name` segments must be exactly the input's path parameters.
  annotation Route
  end

  # The HTTP status of a result type: `@[Punch::Status(201)]`. Default 200.
  # From 400 on, the result is rendered as Problem Details (docs/openapi.md).
  annotation Status
  end

  # Raises the request body limit of one Command, in bytes:
  # `@[Punch::BodyLimit(10 * 1024 * 1024)]`.
  annotation BodyLimit
  end

  # Leaves an operation out of `openapi.json` (and later `/llms.txt`): its
  # route answers, but it is not part of the app's published API. For
  # Punch's own console and webhook endpoints; an app's operations stay
  # listed.
  annotation Unlisted
  end

  # The Commands whose forms a page holds, besides the Command its name
  # gives (`SendPage` holds `Send`): `@[Punch::Forms(Send, Destroy)]`. A
  # browser that submits one of them and is refused sees this page again,
  # with the errors (docs/views.md).
  annotation Forms
  end

  # Business logic without HTTP. Subclass `Query` or `Command`, declare an
  # `Input`, its `Output`, and `call`:
  #
  # ```
  # module Billing::Invoices
  #   struct Send < Punch::Command
  #     struct Input
  #       include Punch::Input
  #
  #       @[Punch::PathParam]
  #       getter invoice_id : ID
  #
  #       getter recipient : Punch::Email
  #     end
  #
  #     alias Output = Sent | NotFound | AlreadySent
  #
  #     def call(input : Input, db : Punch::Writer) : Output
  #     end
  #   end
  # end
  # # derived: POST /billing/invoices/:invoice_id/send
  # ```
  abstract struct Operation
    # In the OpenAPI build only: records the declared return type of `call`
    # as `PunchDeclaredResult`, resolved in the operation's own scope, so
    # the document shows the contract and not what a body happens to
    # return today.
    #
    # In every build: records the types of `call`'s parameters after the
    # input and the handle (the actor, `Punch::Auth::Authentication`) as
    # `PunchCallExtras`, a tuple resolved in the operation's own scope, so
    # that `Auth::Actor` means the app's actor and not `Punch::Auth::Actor`
    # (docs/auth.md).
    macro inherited
      macro finished
        \{% call = @type.methods.find { |method| method.name == "call" } %}
        \{% if call %}
          \{% for arg in call.args[2..-1] %}
            \{% arg.raise "#{@type}#call: give `#{arg.name}` a type: the app's actor, Punch::Grant, Punch::Auth::Authentication, Punch::Auth::PasswordCheck, or Punch::Events (lib/punch/docs/auth.md)" unless arg.restriction %}
          \{% end %}
          # :nodoc:
          alias PunchCallExtras = Tuple(\{{ call.args[2..-1].map(&.restriction).splat }})
          \{% lives = @type.methods.select { |method| method.name == "live" } %}
          \{% unless lives.empty? %}
            \{% lives[0].raise "#{@type}#live: only a page is live, and #{@type} is not one (lib/punch/docs/views.md)." unless @type < ::Punch::Page %}
            \{% for method in lives %}
              \{% unless method.args.size == call.args.size + 1 && method.args[0].restriction %}
                \{% method.raise "#{@type}#live takes the event first, its type stated, then what `call` takes: live(event : SomeEvent, #{call.args.map(&.id).join(", ").id}) : Punch::TurboStream? (lib/punch/docs/views.md)." %}
              \{% end %}
              \{% listened = method.args[0].restriction.resolve %}
              \{% if listened.union? %}
                \{% method.raise "#{@type}#live takes #{listened}: define one `live` per event type (lib/punch/docs/views.md)." %}
              \{% end %}
              \{% unless ::Punch::Event.includers.any? { |type| type <= listened || type.all_subclasses.any? { |subclass| subclass <= listened } } %}
                \{% method.raise "#{@type}#live takes #{listened}, which is no event and which no event includes or inherits (lib/punch/docs/events.md)." %}
              \{% end %}
            \{% end %}
            # The events this live page takes, one per `live`, in the
            # page's scope. :nodoc:
            alias PunchLiveEvents = Tuple(\{{ lives.map { |method| method.args[0].restriction }.splat }})
          \{% end %}
          {% if flag?(:punch_openapi) %}
            \{% unless call.return_type.is_a?(Nop) %}
              # :nodoc:
              alias PunchDeclaredResult = \{{ call.return_type }}
            \{% end %}
          {% end %}
        \{% end %}
        \{% limits = @type.annotations(::Punch::RateLimit) %}
        \{% unless limits.empty? %}
          \{% if @type.annotation(::Punch::RateLimitExempt) %}
            \{% @type.raise "#{@type} has rate limits and @[Punch::RateLimitExempt]; keep one." %}
          \{% end %}
          # The limiters of `@[Punch::RateLimit]`, in order. :nodoc:
          PUNCH_RATE_LIMITS = {
            \{% for limit in limits %}
              \{% unless limit[0].is_a?(NumberLiteral) && limit[0] > 0 %}
                \{% limit.raise "@[Punch::RateLimit] on #{@type}: the first argument is how many requests, a positive number, such as @[Punch::RateLimit(5, per: 1.minute, by: :ip)]" %}
              \{% end %}
              \{% limit.raise "@[Punch::RateLimit] on #{@type} needs `per:`, the period, such as `per: 1.minute`" unless limit[:per] %}
              \{% limit.raise "@[Punch::RateLimit] on #{@type} needs `by:` — :ip, :actor, :token, or an input field such as :email" unless limit[:by].is_a?(SymbolLiteral) %}
              \{% store = limit[:store] || :memory %}
              \{% limit.raise "@[Punch::RateLimit] on #{@type}: `store:` is :memory or :durable, not #{store}" unless store == :memory || store == :durable %}
              \{% name = limit[:name] || (@type.name.split("::").map(&.underscore).join(".") + "." + limit[:by].id.stringify) %}
              ::Punch::RateLimits::Limiter.new(\{{ name }}, \{{ limit[0] }}, per: \{{ limit[:per] }}, store: \{{ store }}, by: \{{ limit[:by].id.stringify }}),
            \{% end %}
          }
        \{% end %}
        \{% if exempt = @type.annotation(::Punch::RateLimitExempt) %}
          \{% unless exempt[0].is_a?(StringLiteral) && !exempt[0].empty? %}
            \{% exempt.raise "@[Punch::RateLimitExempt] on #{@type} takes the reason, such as @[Punch::RateLimitExempt(\"signed webhook; the provider retries\")]" %}
          \{% end %}
        \{% end %}
        \{% if policy = @type.annotation(::Punch::Authorize) %}
          \{% @type.raise "#{@type} has @[Punch::Authorize] and @[Punch::Public]; keep one." if @type.annotation(::Punch::Public) %}
          \{% policy.raise "@[Punch::Authorize] on #{@type} takes one policy, a type that includes Punch::Policy, such as @[Punch::Authorize(Punch::SignedIn)]" unless policy.args.size == 1 && policy.named_args.empty? %}
          # The policy of `@[Punch::Authorize]`, resolved where the
          # operation is written. :nodoc:
          alias PunchPolicy = \{{ policy[0] }}
        \{% end %}
        \{% if forms = @type.annotation(::Punch::Forms) %}
          # The Commands of `@[Punch::Forms]`, resolved where the page is
          # written. :nodoc:
          alias PunchForms = Tuple(\{{ forms.args.splat }})
        \{% end %}
      end
    end

    # The path of this operation's route with *params* filled in, checked at
    # compile time against the input's path parameters:
    # `Billing::Invoices::Send.path(invoice_id: id)`.
    def self.path(**params : **T) : String forall T
      {% begin %}
        {% raise "#{@type} has no Input" unless @type.has_constant?("Input") %}
        {% input = parse_type("::#{@type}::Input").resolve %}
        {% fields = input.instance_vars.select(&.annotation(Punch::PathParam)) %}
        {% names = fields.map(&.name.stringify) %}
        {% for key in T.keys %}
          {% raise "#{@type}.path: unknown path parameter `#{key}`. Path parameters: #{names.empty? ? "none" : names.join(", ").id}" unless names.includes?(key.stringify) %}
        {% end %}
        {% for field in fields %}
          {% given = T[field.name] %}
          {% raise "#{@type}.path: missing path parameter `#{field.name}` (#{field.type})" unless given %}
          {% raise "#{@type}.path: `#{field.name}` must be #{field.type}, not #{given}" unless given <= field.type %}
        {% end %}
        Punch::Routing.fill(Punch::Routing.template({{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}), {
          {% for field in fields %} {{ field.name.stringify }} => Punch::Routing.segment(params[{{ field.name.symbolize }}]), {% end %}
        } of String => String)
      {% end %}
    end
  end

  # A safe read: receives a `Reader`, answers `GET`.
  abstract struct Query < Operation
  end

  # A state change: receives a `Writer`, answers `POST`, `PATCH`, or
  # `DELETE`.
  abstract struct Command < Operation
    # Where a form for this Command is sent, checked like `path`:
    # `v.form(Billing::Invoices::Send.action(invoice_id: id)) { ... }`
    # (docs/views.md).
    def self.action(**params : **T) : Punch::Action forall T
      {% begin %}
        Punch::Action({{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}).new(path(**params), ->(authorizer : Punch::Policy::Authorizer) { Punch::Grant({{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}).permitted?(authorizer, **params) })
      {% end %}
    end
  end

  # A Command with its path filled in: the target of a form
  # (`Command.action`).
  struct Action(C)
    # The Command's path, such as `/billing/invoices/42/send`.
    getter path : String

    # Asks the Command's policy whether the viewer may submit this form.
    # :nodoc:
    getter permit : Proc(Policy::Authorizer, Bool)

    # :nodoc:
    def initialize(@path : String, @permit : Proc(Policy::Authorizer, Bool))
    end

    # The Command's method: `POST`, `PATCH`, `PUT`, or `DELETE`.
    def method : String
      Routing.method(C)
    end

    # What a form's `action` holds. A form can only `POST`, so another
    # method travels as `?_method=PATCH`, which the router honours for form
    # bodies only.
    def url : String
      verb = method
      verb == "POST" ? @path : "#{@path}?_method=#{verb}"
    end
  end
end

require "./authorization"
require "./roles"
require "./authorization/explain"
