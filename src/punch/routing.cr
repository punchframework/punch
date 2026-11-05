require "./operation"
require "./page"
require "./submission"
require "./raw_request"
require "./llms"

module Punch
  # Route derivation, three rules:
  #
  # 1. The namespace is the path: `Billing::Invoices` is `/billing/invoices`.
  # 2. Reserved names have REST shapes: `Index` (GET), `Show` (GET),
  #    `Create` (POST), `Update` (PATCH), `Destroy` (DELETE). Any other name
  #    is appended as a segment, `GET` for a Query and `POST` for a Command.
  # 3. Path parameters become segments. One named `customer_id` follows the
  #    namespace segment `customers` (or `customer`); the others are appended
  #    in declaration order.
  #
  # `@[Punch::Route(method, path)]` overrides all three. Two operations on
  # the same method and path shape do not compile, except a `Page` and a
  # `Query`, which share it: the router picks by `Accept`.
  module Routing
    alias EndpointProc = Proc(HTTP::Context, Hash(String, String), Database, HTTP::Response)

    # What answers a route: JSON for a Query or a Command, HTML for a Page.
    enum Kind
      Query
      Command
      Page

      # The representation it serves: `json` or `html`.
      def surface : String
        page? ? "html" : "json"
      end
    end

    # One row of the route table. `segments` holds literal segments and
    # `:name` for parameters.
    record Route, method : String, template : String, segments : Array(String),
      operation : String, operation_id : String, kind : Kind, handler : EndpointProc,
      form_page : String? = nil, rate_limits : Array(RateLimits::Limiter) = [] of RateLimits::Limiter,
      actor : String = "none", rate_limit_exempt : String? = nil, policy : String? = nil, public : Bool = false,
      unlisted : Bool = false, agent_readable : Bool = false, entry : Bool = false, live : Bool = false do
      # The representations it serves (`punch routes`): JSON for Queries and
      # Commands, HTML for pages, markdown for pages agents read,
      # server-sent events for live pages; a Command whose form a page holds
      # also answers that form, as HTML, and as markdown for agents.
      def surfaces : Array(String)
        case kind
        in .page?
          surfaces = agent_readable ? ["html", "markdown"] : ["html"]
          surfaces << "live" if live
          surfaces
        in .query?
          ["json"]
        in .command?
          form_page ? ["json", "html", "markdown"] : ["json"]
        end
      end
    end

    # The route table, derived at compile time from every concrete
    # `Punch::Operation`.
    class_getter routes : Array(Route) { derive }

    @@templates : Hash(String, String)?
    @@methods : Hash(String, String)?
    @@by_operation : Hash(String, Route)?

    # The route of *operation*.
    def self.route(operation : Operation.class) : Route
      by_operation = @@by_operation ||= routes.to_h { |route| {route.operation, route} }
      by_operation[operation.name]
    end

    # The path template of *operation*, such as
    # `/billing/invoices/:invoice_id/send`.
    def self.template(operation : Operation.class) : String
      templates = @@templates ||= routes.to_h { |route| {route.operation, route.template} }
      templates[operation.name]
    end

    # The method of *operation*'s route, such as `PATCH`.
    def self.method(operation : Operation.class) : String
      methods = @@methods ||= routes.to_h { |route| {route.operation, route.method} }
      methods[operation.name]
    end

    # The suffix that asks for a page's markdown by URL:
    # `/billing/invoices/42.md`, and `/index.md` for `/`.
    MARKDOWN_SUFFIX = ".md"
    MARKDOWN_INDEX  = "/index.md"

    @@readable : Set(String)?

    # Whether the page named *page* (`Billing::Invoices::ShowPage`) is
    # agent-readable, so its markdown answers at its `.md` URL.
    def self.agent_readable?(page : String) : Bool
      readable = @@readable ||= routes.select(&.agent_readable).map(&.operation).to_set
      readable.includes?(page)
    end

    # *url* (a path with an optional query) with the markdown suffix on its
    # path: `/billing/invoices.md?filter[status]=draft`.
    def self.markdown_url(url : String) : String
      path, mark, query = url.partition('?')
      (path == "/" ? MARKDOWN_INDEX : path + MARKDOWN_SUFFIX) + mark + query
    end

    # Where *href* leads an agent reading markdown: the page's `.md` URL
    # when it is agent-readable, so an agent that sends no `Accept` stays on
    # markdown; any other link as it is, since its `.md` URL is a 404.
    def self.markdown_url(href : Href) : String
      page = href.page
      page && agent_readable?(page) ? markdown_url(href.url) : href.url
    end

    # Fills the `:name` segments of *template* from *values*, escaped.
    def self.fill(template : String, values : Hash(String, String)) : String
      return template if values.empty?

      template.split('/').join('/') do |segment|
        segment.starts_with?(':') ? URI.encode_path_segment(values[segment[1..]]) : segment
      end
    end

    # The text of a value in a path, the inverse of `Input::Read.string`.
    def self.segment(value : Enum) : String
      value.to_s.underscore
    end

    def self.segment(value : Time) : String
      value.to_rfc3339
    end

    def self.segment(value) : String
      value.to_s
    end

    # Runs one operation for one request: parse, authenticate, call,
    # render. Besides the input and the database handle, `call` may take
    # the app's actor (`Punch::Auth::Actor`; nilable when optional) and the
    # request's `Punch::Locale`, and in a Command `Punch::Auth::Authentication`,
    # `Punch::Auth::PasswordCheck`, `Punch::Auth::OwnPasswordCheck`,
    # `Punch::Auth::SecondFactorCheck`, `Punch::Auth::OwnSecondFactorCheck`,
    # `Punch::Events(...)`, `Punch::Jobs(...)`, and `Punch::RawRequest`,
    # in a Command or a page `Punch::Auth::Reveal`, recognized by their types
    # (docs/auth.md, docs/events.md, docs/jobs.md, docs/translations.md,
    # docs/operations.md).
    def self.endpoint(operation : O.class, context : HTTP::Context, params : Hash(String, String), database : Database) : HTTP::Response forall O
      {% begin %}
      {% page = O < Punch::Page %}
      {% holder = nil %}
      {% if O < Punch::Command %}
        {% pages = Punch::Page.all_subclasses.reject(&.abstract?) %}
        {% holder = pages.find { |candidate| candidate.has_constant?("PunchForms") && parse_type("::#{candidate}::PunchForms").resolve.type_vars.includes?(O) } ||
                    pages.find { |candidate| candidate.name.stringify == "#{O}Page" } %}
      {% end %}
      {% actor = nil %}
      {% optional = false %}
      {% auth = false %}
      {% check = false %}
      {% own_check = false %}
      {% factor_check = false %}
      {% own_factor_check = false %}
      {% grant = false %}
      {% events = nil %}
      {% jobs = nil %}
      {% raw = false %}
      {% reveal = false %}
      {% arguments = [] of StringLiteral %}
      {% call_def = O.methods.find { |definition| definition.name == "call" } %}
      {% for type, position in parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
        {% arg = call_def.args[position + 2] %}
        {% if type.name(generic_args: false) == "Punch::Grant" %}
          {% arg.raise "#{O}#call takes #{type}, but a grant proves the policy of the operation it is given to: Punch::Grant(#{O})." unless type.type_vars[0] == O %}
          {% arg.raise "#{O}#call takes #{type}, but #{O} has no policy to make one. Declare it with @[Punch::Authorize(Policy)] (lib/punch/docs/authorization.md)." unless O.has_constant?("PunchPolicy") %}
          {% grant = true %}
          {% arguments << "grant" %}
        {% elsif type.name(generic_args: false) == "Punch::Events" %}
          {% arg.raise "#{O} is a #{O < Punch::Page ? "Page".id : "Query".id}; only a Command publishes events, so only a Command takes #{type} (lib/punch/docs/events.md)." unless O < Punch::Command %}
          {% arg.raise "#{O}#call takes Punch::Events twice; list every event in one: Punch::Events(A | B)." if events %}
          {% published = type.type_vars[0] %}
          {% for member in (published.union? ? published.union_types : [published]) %}
            {% arg.raise "#{O}#call takes #{type}, but #{member} is not an event. An event is a struct that includes Punch::Event (lib/punch/docs/events.md)." unless member < Punch::Event %}
          {% end %}
          {% events = type %}
          {% arguments << "events" %}
        {% elsif type.name(generic_args: false) == "Punch::Jobs" %}
          {% arg.raise "#{O} is a #{O < Punch::Page ? "Page".id : "Query".id}; only a Command enqueues jobs, so only a Command takes #{type} (lib/punch/docs/jobs.md)." unless O < Punch::Command %}
          {% arg.raise "#{O}#call takes Punch::Jobs twice; list every job in one: Punch::Jobs(A | B)." if jobs %}
          {% enqueued = type.type_vars[0] %}
          {% for member in (enqueued.union? ? enqueued.union_types : [enqueued]) %}
            {% arg.raise "#{O}#call takes #{type}, but #{member} is not a job. A job is a struct that includes Punch::Job (lib/punch/docs/jobs.md)." unless member < Punch::Job %}
          {% end %}
          {% jobs = type %}
          {% arguments << "jobs" %}
        {% elsif type == Punch::Auth::Authentication %}
          {% arg.raise "#{O} is a Query; only a Command can sign in or out, so only a Command takes Punch::Auth::Authentication." unless O < Punch::Command %}
          {% auth = true %}
          {% arguments << "authentication_handle" %}
        {% elsif type == Punch::Locale %}
          {% arguments << "context.locale" %}
        {% elsif type == Punch::RawRequest %}
          {% arg.raise "#{O} is a #{O < Punch::Page ? "Page".id : "Query".id}; only a Command reads a body, so only a Command takes Punch::RawRequest." unless O < Punch::Command %}
          {% raw = true %}
          {% arguments << "raw_request" %}
        {% elsif type == Punch::Auth::Reveal %}
          {% arg.raise "#{O} is a Query; a Command shows a secret once and the page after its form takes it, so only those take Punch::Auth::Reveal (lib/punch/docs/auth.md)." unless O < Punch::Command || page %}
          {% reveal = true %}
          {% arguments << "reveal" %}
        {% elsif type == Punch::Auth::PasswordCheck %}
          {% arg.raise "#{O} is a Query; only a Command checks a password, so only a Command takes Punch::Auth::PasswordCheck." unless O < Punch::Command %}
          {% check_input = parse_type("::#{O}::Input").resolve %}
          {% email_field = check_input.instance_vars.find { |ivar| ivar.name.stringify == "email" } %}
          {% password_field = check_input.instance_vars.find { |ivar| ivar.name.stringify == "password" } %}
          {% unless email_field && email_field.type == Punch::Email && password_field && password_field.type == Punch::Auth::Password %}
            {% call_def.raise "#{O} takes Punch::Auth::PasswordCheck, so its input needs `getter email : Punch::Email` and `getter password : Punch::Auth::Password` (lib/punch/docs/auth.md)" %}
          {% end %}
          {% unless O.annotations(Punch::RateLimit).any? { |limit| limit[:by] == :email } %}
            {% call_def.raise "#{O} checks passwords, so it needs a rate limit per account: @[Punch::RateLimit(10, per: 15.minutes, by: :email)] (lib/punch/docs/auth.md)" %}
          {% end %}
          {% check = true %}
          {% arguments << "password_check" %}
        {% elsif type == Punch::Auth::OwnPasswordCheck %}
          {% arg.raise "#{O} is a Query; only a Command checks a password, so only a Command takes Punch::Auth::OwnPasswordCheck." unless O < Punch::Command %}
          {% own_input = parse_type("::#{O}::Input").resolve %}
          {% current_field = own_input.instance_vars.find { |ivar| ivar.name.stringify == "current_password" } %}
          {% unless current_field && current_field.type == Punch::Auth::Password %}
            {% call_def.raise "#{O} takes Punch::Auth::OwnPasswordCheck, so its input needs `getter current_password : Punch::Auth::Password` (lib/punch/docs/auth.md)" %}
          {% end %}
          {% unless O.annotations(Punch::RateLimit).any? { |limit| limit[:by] == :actor } %}
            {% call_def.raise "#{O} checks the user's password, so it needs a rate limit per user: @[Punch::RateLimit(10, per: 15.minutes, by: :actor)] (lib/punch/docs/auth.md)" %}
          {% end %}
          {% own_check = true %}
          {% arguments << "own_password_check" %}
        {% elsif type == Punch::Auth::SecondFactorCheck || type == Punch::Auth::OwnSecondFactorCheck %}
          {% arg.raise "#{O} is a Query; only a Command checks a second factor, so only a Command takes #{type}." unless O < Punch::Command %}
          {% code_field = parse_type("::#{O}::Input").resolve.instance_vars.find { |ivar| ivar.name.stringify == "code" } %}
          {% unless code_field && code_field.type == Punch::Auth::OneTimeCode %}
            {% call_def.raise "#{O} takes #{type}, so its input needs `getter code : Punch::Auth::OneTimeCode` (lib/punch/docs/auth.md)" %}
          {% end %}
          {% if type == Punch::Auth::SecondFactorCheck %}
            {% unless O.annotations(Punch::RateLimit).any? { |limit| limit[:by] == :challenge } %}
              {% call_def.raise "#{O} checks second factors, so it needs a rate limit per user: @[Punch::RateLimit(5, per: 15.minutes, by: :challenge, store: :durable)] (lib/punch/docs/auth.md)" %}
            {% end %}
            {% factor_check = true %}
            {% arguments << "second_factor_check" %}
          {% else %}
            {% unless O.annotations(Punch::RateLimit).any? { |limit| limit[:by] == :actor } %}
              {% call_def.raise "#{O} checks the user's second factor, so it needs a rate limit per user: @[Punch::RateLimit(5, per: 15.minutes, by: :actor, store: :durable)] (lib/punch/docs/auth.md)" %}
            {% end %}
            {% own_factor_check = true %}
            {% arguments << "own_second_factor_check" %}
          {% end %}
        {% else %}
          {% members = type.union? ? type.union_types.reject(&.==(Nil)) : [type] %}
          {% unless members.size == 1 && members[0] < Punch::Auth::Actor %}
            {% arg.raise "#{O}#call takes #{type}, which is neither the app's actor (a type that includes Punch::Auth::Actor), Punch::Auth::Authentication, Punch::Auth::PasswordCheck, Punch::Auth::OwnPasswordCheck, Punch::Auth::SecondFactorCheck, Punch::Auth::OwnSecondFactorCheck, Punch::Events, Punch::Jobs, Punch::Locale, Punch::RawRequest, nor Punch::Auth::Reveal (lib/punch/docs/auth.md, lib/punch/docs/events.md, lib/punch/docs/jobs.md, lib/punch/docs/translations.md, lib/punch/docs/operations.md)" %}
          {% end %}
          {% arg.raise "#{O}#call takes an actor twice." if actor %}
          {% actor = members[0] %}
          {% optional = type.union? %}
          {% arguments << "actor" %}
        {% end %}
      {% end %}
      {% if own_check %}
        {% call_def.raise "#{O} takes Punch::Auth::OwnPasswordCheck, so its `call` must take the app's actor, required: the password checked is the actor's (lib/punch/docs/auth.md)." if !actor || optional %}
      {% end %}
      {% if own_factor_check %}
        {% call_def.raise "#{O} takes Punch::Auth::OwnSecondFactorCheck, so its `call` must take the app's actor, required: the code checked is the actor's (lib/punch/docs/auth.md)." if !actor || optional %}
      {% end %}
      {% if reveal %}
        {% call_def.raise "#{O} takes Punch::Auth::Reveal, so its `call` must take the app's actor: the secret is shown to the session that made it (lib/punch/docs/auth.md)." unless actor %}
      {% end %}
      {% if factor_check %}
        {% call_def.raise "#{O} takes Punch::Auth::SecondFactorCheck, so its `call` takes Punch::Auth::Authentication too: the check signs in (lib/punch/docs/auth.md)." unless auth %}
      {% end %}
      {% if check %}
        {% failed_events = events ? (events.type_vars[0].union? ? events.type_vars[0].union_types : [events.type_vars[0]]) : [] of TypeNode %}
        {% unless failed_events.includes?(Punch::Auth::SignInFailed) %}
          {% call_def.raise "#{O} checks passwords, so its `call` takes `events : Punch::Events(... | Punch::Auth::SignInFailed)`: Punch publishes it when the sign-in is refused (lib/punch/docs/auth.md)." %}
        {% end %}
      {% end %}
      {% policy = O.has_constant?("PunchPolicy") %}
      {% if policy %}
        {% policy_type = parse_type("::#{O}::PunchPolicy").resolve %}
        {% O.annotation(Punch::Authorize).raise "#{O}: @[Punch::Authorize(#{policy_type})] names a type that is not a policy. A policy includes Punch::Policy and defines `self.check` (lib/punch/docs/authorization.md)." unless policy_type < Punch::Policy %}
        {% call_def.raise "#{O} has a policy, so its `call` must take the app's actor (or a nilable one, if anyone may ask): the policy decides for it (lib/punch/docs/authorization.md)." unless actor %}
        {% path_names = parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)).map(&.name.stringify) %}
        {% checks = policy_type.class.methods.select { |method| method.name.stringify == "check" } %}
        {% unless checks.empty? %}
          {% takes = [] of String %}
          {% fits = false %}
          {% for method in checks %}
            {% own = (method.args.size > 2 && method.args[2].name.stringify == "operation" ? method.args[3..-1] : method.args[2..-1]).reject(&.name.stringify.empty?) %}
            {% if method.double_splat %}
              {% fits = true %}
            {% else %}
              {% names = own.map(&.name.stringify) %}
              {% required = own.reject { |own_arg| !own_arg.default_value.is_a?(Nop) }.map(&.name.stringify) %}
              {% fits = true if path_names.all? { |name| names.includes?(name) } && required.all? { |name| path_names.includes?(name) } %}
              {% takes = names %}
            {% end %}
          {% end %}
          {% unless fits %}
            {% wanted = takes.empty? ? "no keyword" : takes.map { |name| "`" + name + "`" }.join(", ") %}
            {% given = path_names.empty? ? "no path parameter" : (path_names.size == 1 ? "the path parameter " : "the path parameters ") + path_names.map { |name| "`" + name + "`" }.join(", ") %}
            {% checks[0].raise "#{policy_type}.check takes #{wanted.id}, but #{O} has #{given.id}. A policy's `check` takes the operation's path parameters as keywords (lib/punch/docs/authorization.md)." %}
          {% end %}
        {% end %}
        {% if O < Punch::Command && !grant %}
          {% call_def.raise "#{O} is a Command with a policy, so its `call` must take `grant : Punch::Grant(#{O.name.split("::").last.id})`, the proof that the policy allowed it (lib/punch/docs/authorization.md)." %}
        {% end %}
      {% end %}
      {% rate_limits = O.annotations(Punch::RateLimit) %}
      {% limit_input = parse_type("::#{O}::Input").resolve %}
      {% for limit, index in rate_limits %}
        {% by = limit[:by].id.stringify %}
        {% if by == "ip" %}
          # Before the body is read.
          if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], RateLimits.ip_key(context.client_ip), context)
            return RateLimits.respond(limited, context)
          end
        {% elsif by == "actor" || by == "token" %}
          {% limit.raise "#{O} is limited by :#{by.id}, so its `call` must take the app's actor (lib/punch/docs/auth.md)" unless actor %}
        {% elsif by == "challenge" %}
          {% limit.raise "#{O} is limited by :challenge, so its `call` must take Punch::Auth::SecondFactorCheck (lib/punch/docs/auth.md)" unless factor_check %}
        {% elsif !limit_input.instance_vars.any? { |ivar| ivar.name.stringify == by } %}
          {% limit.raise "#{O} is limited by :#{by.id}, which is not :ip, :actor, :token, or a field of its input (#{limit_input.instance_vars.map(&.name).join(", ").id})" %}
        {% end %}
      {% end %}
      {% if holder %}
        form = nil.as(URI::Params?)
      {% end %}
      {% declared = O.annotation(Punch::Idempotency) %}
      {% keyed = O < Punch::Command && !auth && !check && !reveal && (actor || (declared && declared[:scope])) %}
      {% if keyed %}
        keyed_body = ""
      {% end %}
      parse = context.span.child("input")
      input = begin
        {% if O < Punch::Command %}
          limit = {% if limit = O.annotation(Punch::BodyLimit) %} {{ limit[0] }} {% else %} context.config.max_body_size {% end %}

          case body = context.read_body(limit)
          in HTTP::BodyTooLarge then return HTTP::Response.problem(:payload_too_large, context)
          in String
            {% if keyed %}
              keyed_body = body
            {% end %}
            {% if raw %}
              raw_request = Punch::RawRequest.new(body, context.request.headers)
              # The body, of whatever type, is the Command's to read after
              # checking it: only path parameters are parsed.
              O::Input.from_json("", params)
            {% else %}
            {% if holder %}
              # A browser's form: answered as Turbo Drive expects, with a
              # 303 or the page that holds the form (docs/views.md).
              if form?(context)
                context.span.set("punch.surface", context.markdown? ? "markdown" : "html")
                form = URI::Params.parse(body)
                O::Input.from_form(form, params)
              else
            {% end %}
            return HTTP::Response.problem(:unsupported_media_type, context) unless body.blank? || json?(context)

            O::Input.from_json(body, params)
            {% if holder %}
              end
            {% end %}
            {% end %}
          end
        {% else %}
          O::Input.from_query(context.request.query_params, params)
        {% end %}
      ensure
        parse.finish
      end
      {% if declared && !(O < Punch::Command) %}
        Routing.idempotency(O) # its compile-time checks
      {% end %}
      {% if keyed %}
        # Before the input is answered: a bad key is the client's mistake
        # whatever the body says.
        attempt = IdempotencyKeys.attempt(context, {{ O.name.stringify }}, Routing.idempotency(O), {{ declared ? declared[:scope] : nil }},
          keyed_body, {% if holder %} form {% else %} nil {% end %})
        return attempt if attempt.is_a?(HTTP::Response)
      {% elsif O < Punch::Command %}
        {% if declared %}
          Routing.idempotency(O) # its compile-time checks
        {% end %}
        if refused = IdempotencyKeys.refuse_unaccepted(context)
          return refused
        end
      {% end %}

      case input
      in Punch::Rejection
        {% if actor %}
          actor_locale(context, database, {{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }})
        {% end %}
        {% if page %}
          Pages.rejected(input, context, {{ parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)).map(&.name.stringify) }} of String)
        {% elsif holder %}
          form ? Submissions.rejected({{ holder.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, O, input, form, context, params, database) : rejected(input, context, {{ parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)).map(&.name.stringify) }} of String)
        {% else %}
          rejected(input, context, {{ parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)).map(&.name.stringify) }} of String)
        {% end %}
      in O::Input
        {% for limit, index in rate_limits %}
          {% by = limit[:by].id.stringify %}
          {% unless by == "ip" || by == "actor" || by == "token" || by == "challenge" %}
            if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], RateLimits.key(input.@{{ by.id }}), context)
              return RateLimits.respond(limited, context)
            end
          {% end %}
        {% end %}
        {% if actor && !optional %}
          {% if holder %}
            return (form ? Pages.unauthenticated(context) : Auth.unauthenticated(context)) unless Auth.presented?(context)
          {% else %}
            return {{ page ? "Pages".id : "Auth".id }}.unauthenticated(context) unless Auth.presented?(context)
          {% end %}
        {% end %}
        {% if own_check %}
          # Whose password it is, and their limits, before any hashing:
          # a request without a working session or token hashes nothing.
          own_principal = Auth.presented?(context) ? database.read { |reader| Auth.authenticate(context, reader, Time.utc) }.as?(Punch::Auth::Principal) : nil
          {% if holder %}
            return (form ? Pages.unauthenticated(context) : Auth.unauthenticated(context)) unless own_principal
          {% else %}
            return Auth.unauthenticated(context) unless own_principal
          {% end %}
          {% for limit, index in rate_limits %}
            {% if limit[:by].id.stringify == "actor" %}
              if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], own_principal.user_id.to_s, context)
                return RateLimits.respond(limited, context)
              end
            {% end %}
          {% end %}
        {% end %}
        {% if O < Punch::Command %}
          # Password work runs on the hasher before the transaction opens,
          # never inside it: the writer would wait for it.
          {% for ivar in limit_input.instance_vars %}
            {% if ivar.type == Punch::Auth::NewPassword %}
              return Auth::Passwords.busy(context) if Auth::Passwords.prepare(input.@{{ ivar.name }}, context.span)
            {% elsif ivar.type.union? && ivar.type.union_types.includes?(Punch::Auth::NewPassword) %}
              if (new_password = input.@{{ ivar.name }}) && Auth::Passwords.prepare(new_password, context.span)
                return Auth::Passwords.busy(context)
              end
            {% end %}
          {% end %}
        {% end %}
        {% if check %}
          password_check = Auth::Passwords.check(database, input.email, input.password, context.span)
          return Auth::Passwords.busy(context) if password_check.is_a?(Auth::PasswordsBusy)
        {% end %}
        {% if own_check %}
          own_password_check = Auth::Passwords.check_own(database, own_principal.user_id, input.current_password, context.span)
          return Auth::Passwords.busy(context) if own_password_check.is_a?(Auth::PasswordsBusy)
        {% end %}
        {% if factor_check %}
          # Whose challenge the browser holds: the key of the limits that
          # cap guessing.
          second_factor_check = Auth::SecondFactors.challenge(database, context, input.code)
          {% for limit, index in rate_limits %}
            {% if limit[:by].id.stringify == "challenge" %}
              if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], second_factor_check.user_id.try(&.to_s), context)
                return RateLimits.respond(limited, context)
              end
            {% end %}
          {% end %}
        {% end %}
        {% if page && O.has_constant?("PunchLiveEvents") %}
          # A live page's stream, or the page with where its stream
          # starts, taken before its snapshot (docs/views.md).
          unless context.markdown?
            return Routing.live(O, context, input, database) if Live.requested?(context)

            context.live_position = Live.hub.position
            # Shown again after a refused form: the request is the Command's.
            context.live_path = O.path_of(input).url unless context.request.method == "GET"
          end
        {% end %}
        {% if actor || auth %}
          now = Time.utc
        {% end %}
        {% db = O < Punch::Command ? "writer" : "reader" %}
        {% if auth %}
          authentication = nil.as(Punch::Auth::Authentication?)
        {% end %}
        {% if reveal %}
          revealed = nil.as(Punch::Auth::Reveal?)
        {% end %}
        result = database.{{ (O < Punch::Command ? "write" : "read").id }} do |{{ db.id }}|
          {% if actor || auth %}
            principal = Punch::Auth.authenticate(context, {{ db.id }}, now)
            next Punch::Auth::Unauthenticated.new if principal.is_a?(Punch::Auth::Refused)
          {% end %}
          {% if actor %}
            actor = principal ? {{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.load(principal, {{ db.id }}) : nil
            {% unless optional %}
              next Punch::Auth::Unauthenticated.new unless actor
            {% end %}
            # The actor's stored locale wins over Accept-Language.
            I18n.prefer(context, actor.locale) if actor
          {% end %}
          {% for limit, index in rate_limits %}
            {% by = limit[:by].id.stringify %}
            {% if by == "actor" && !own_check %}
              if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], principal.try(&.user_id.to_s), context)
                next limited
              end
            {% elsif by == "token" %}
              if limited = RateLimits.limited(O::PUNCH_RATE_LIMITS[{{ index }}], principal.try(&.api_token).try(&.id.to_s), context)
                next limited
              end
            {% end %}
          {% end %}
          {% if policy %}
            # Inside the transaction, so the decision cannot be raced.
            grant = Punch::Grant(O).check(actor, {{ db.id }}{% for ivar in limit_input.instance_vars.select(&.annotation(Punch::PathParam)) %}, {{ ivar.name }}: input.@{{ ivar.name }}{% end %})
            next grant unless grant.is_a?(Punch::Grant(O))
          {% end %}
          {% if keyed %}
            # After authentication and the policy: a replay answers only
            # whom the Command would have answered.
            if (pending = attempt) && (replay = IdempotencyKeys.claim(pending, {{ db.id }}, context))
              next replay
            end
          {% end %}
          {% if own_factor_check %}
            own_second_factor_check = Punch::Auth::OwnSecondFactorCheck.new(principal.try(&.user_id), input.code)
          {% end %}
          {% if events %}
            events = {{ events.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.for_transaction({{ db.id }})
          {% end %}
          {% if jobs %}
            jobs = {{ jobs.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.for_transaction({{ db.id }})
          {% end %}
          {% if reveal %}
            revealed = reveal = Punch::Auth::Reveal.new(principal, context, now)
          {% end %}
          {% if auth %}
            authentication = authentication_handle = Punch::Auth::Authentication.new({{ db.id }}, principal, now: now, ip: context.client_ip, user_agent: context.request.headers["User-Agent"]?)
          {% end %}
          {% if O < Punch::Command %}
            called = O.new.call(input, {{ db.id }}{% for argument in arguments %}, {{ argument.id }}{% end %})
            # A failure writes nothing.
            {{ db.id }}.lease.rollback_only = true if Routing.failure?(O::Input, called)
            {% if keyed %}
              # The answer is stored in the transaction, or right after
              # its rollback for a failure. A refused form is shown again
              # and not stored: it changed nothing.
              if pending = attempt
                failed = {{ db.id }}.lease.rollback_only?
                {% if holder %}
                  if sent = form
                    IdempotencyKeys.keep(pending, {{ db.id }}, Submissions.respond({{ holder.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, O, called, sent, context, params, database, {{ db.id }}), false) unless failed
                  else
                    IdempotencyKeys.keep(pending, {{ db.id }}, render(called, context), failed)
                  end
                {% else %}
                  IdempotencyKeys.keep(pending, {{ db.id }}, render(called, context), failed)
                {% end %}
              end
            {% end %}
            called
          {% elsif page %}
            # Rendered in the transaction, so forms and links ask their
            # policies in the same snapshot. A page that does not ask for
            # the actor does not know who looks, and shows all.
            {% if O.annotation(Punch::AgentReadable) %}
              shown = O.new.call(input, {{ db.id }}{% for argument in arguments %}, {{ argument.id }}{% end %})
              typeof(Routing.declared_statuses(O, shown))
              viewer = {% if actor %} Punch::Policy::Authorizer.new(actor, {{ db.id }}) {% else %} nil {% end %}
              # Only an agent-readable page compiles the markdown, so
              # only its components must be renderable without raw HTML.
              context.markdown? ? Pages.respond(shown, context, viewer, Pages::Markdown) : Pages.respond(shown, context, viewer)
            {% else %}
              shown = O.new.call(input, {{ db.id }}{% for argument in arguments %}, {{ argument.id }}{% end %})
              typeof(Routing.declared_statuses(O, shown))
              Pages.respond(shown, context, {% if actor %} Punch::Policy::Authorizer.new(actor, {{ db.id }}) {% else %} nil {% end %})
            {% end %}
          {% else %}
            O.new.call(input, {{ db.id }}{% for argument in arguments %}, {{ argument.id }}{% end %})
          {% end %}
        end
        {% if keyed %}
          return result.response if result.is_a?(IdempotencyKeys::Replay)
          if (pending = attempt) && (answered = pending.response)
            return answered
          end
        {% end %}
        {% if auth %}
          authentication.try(&.apply(context)) unless Routing.failure?(O::Input, result)
        {% end %}
        {% if reveal && page %}
          revealed.try(&.apply(context))
        {% elsif reveal %}
          # Only a Command that succeeded leaves its secret for the next page.
          revealed.try(&.apply(context)) unless Routing.failure?(O::Input, result)
        {% end %}
        {% if check %}
          # The Command's own events rolled back with it.
          Routing.sign_in_failed({{ events.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, database, password_check) if result.is_a?(Punch::Auth::InvalidCredentials)
        {% end %}
        {% if actor && !(O < Punch::Command) %}
          Auth.touch_later(context, database, now) if context.touch
        {% end %}
        typeof(Routing.declared_statuses(O, result))
        {% if page %}
          result.is_a?(HTTP::Response) ? result : Pages.respond(result, context)
        {% elsif holder %}
          form ? Submissions.respond({{ holder.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, O, result, form, context, params, database) : render(result, context)
        {% else %}
          render(result, context)
        {% end %}
      end
      {% end %}
    end

    # A live page's stream (`Punch::Live`): the page's authentication and
    # policy are asked now, again for every event, and at each keepalive,
    # so a viewer who loses access stops receiving and frees the stream.
    def self.live(operation : O.class, context : HTTP::Context, input : I, database : Database) : HTTP::Response forall O, I
      refused = live_turn(O, nil, input, context, database)
      return Pages.respond(refused, context) if refused.is_a?(Auth::Unauthenticated | Policy::Refused)

      takes = ->(event : Event) { Routing.live_takes?(O, event) }
      turn = ->(event : Event?) {
        answer = Routing.live_turn(O, event, input, context, database)
        answer.is_a?(Auth::Unauthenticated | Policy::Refused) ? Live::Ended.new : answer
      }
      Live.respond(context, takes, turn)
    end

    # Whether a live page *O* takes *event*.
    # :nodoc:
    def self.live_takes?(operation : O.class, event : Event) : Bool forall O
      {% begin %}
        case event
        {% for listened in parse_type("::#{O}::PunchLiveEvents").resolve.type_vars %}
          when {{ listened.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then true
        {% end %}
        else false
        end
      {% end %}
    end

    # One turn of a live page's stream, in a read transaction: who looks
    # and whether the page's policy still lets them, then, for *event*,
    # `live`'s actions rendered for them. Without an event, only the
    # check, when the stream opens.
    # :nodoc:
    def self.live_turn(operation : O.class, event : Event?, input : I, context : HTTP::Context, database : Database) : SafeHTML | Auth::Unauthenticated | Policy::Refused? forall O, I
      {% begin %}
      {% call_def = O.methods.find { |definition| definition.name == "call" } %}
      {% actor = nil %}
      {% optional = false %}
      {% arguments = [] of StringLiteral %}
      {% for type in parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
        {% if type.name(generic_args: false) == "Punch::Grant" %}
          {% arguments << "grant" %}
        {% elsif type == Punch::Locale %}
          {% arguments << "context.locale" %}
        {% elsif type == Punch::Auth::Reveal %}
          {% call_def.raise "#{O} takes Punch::Auth::Reveal, which shows a secret once, so it cannot be a live page: remove `live` (lib/punch/docs/views.md)." %}
        {% else %}
          {% actor = (type.union? ? type.union_types.reject(&.==(Nil)) : [type])[0] %}
          {% optional = type.union? %}
          {% arguments << "actor" %}
        {% end %}
      {% end %}
      database.read do |reader|
        {% if actor %}
          principal = Auth.authenticate(context, reader, Time.utc)
          # An open page does not keep its session alive: only requests do.
          context.touch = nil
          next Punch::Auth::Unauthenticated.new if principal.is_a?(Auth::Refused)
          actor = principal ? {{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.load(principal, reader) : nil
          {% unless optional %}
            next Punch::Auth::Unauthenticated.new unless actor
          {% end %}
          I18n.prefer(context, actor.locale) if actor
        {% end %}
        {% if O.has_constant?("PunchPolicy") %}
          grant = Punch::Grant(O).check(actor, reader{% for ivar in parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)) %}, {{ ivar.name }}: input.@{{ ivar.name }}{% end %})
          next grant unless grant.is_a?(Punch::Grant(O))
        {% end %}
        next unless event
        stream = case event
                 {% for listened in parse_type("::#{O}::PunchLiveEvents").resolve.type_vars %}
                   when {{ listened.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
                     O.new.live(event, input, reader{% for argument in arguments %}, {{ argument.id }}{% end %}).as(Punch::TurboStream?)
                 {% end %}
                 end
        stream.try(&.render({% if actor %} Punch::Policy::Authorizer.new(actor, reader) {% else %} nil {% end %}, context.locale))
      end
      {% end %}
    end

    # Publishes `Punch::Auth::SignInFailed` for a refused sign-in, in a
    # transaction of its own.
    def self.sign_in_failed(handle : H.class, database : Database, check : Auth::PasswordCheck) : Nil forall H
      database.write { |writer| H.for_transaction(writer).publish(Auth::SignInFailed.new(check.email, check.owner_id)) }
    end

    # The actor's stored locale for a rejected input, which is answered
    # before the operation's transaction loads the actor: one read, on
    # the error path only.
    def self.actor_locale(context : HTTP::Context, database : Database, actor : A.class) : Nil forall A
      return unless Auth.presented?(context)

      database.read do |reader|
        principal = Auth.authenticate(context, reader, Time.utc)
        I18n.prefer(context, A.load(principal, reader).try(&.locale)) if principal.is_a?(Auth::Principal)
      end
    end

    # Whether the body is a form, as a browser sends it.
    def self.form?(context : HTTP::Context) : Bool
      context.request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) == "application/x-www-form-urlencoded"
    end

    private def self.json?(context : HTTP::Context) : Bool
      type = context.request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) || return false
      type == "application/json" || (type.starts_with?("application/") && type.ends_with?("+json"))
    end

    # Members of every problem; a failure result's fields must not reuse them.
    PROBLEM_MEMBERS = %w[type title status code detail instance request_id errors]

    # 422 with every error, as Problem Details (RFC 9457) with the code
    # `invalid_input` and an `errors` member: path, code, and params of
    # each, and the code's message in the request's locale where there is
    # one. Programs read the code; the message is for people.
    #
    # A path parameter among *path_params* that does not parse names no
    # resource, so the answer is 404 `not_found`, as for pages: a garbled
    # ID and a well-formed one of no record then look the same.
    def self.rejected(rejection : Rejection, context : HTTP::Context, path_params : Array(String) = [] of String) : HTTP::Response
      context.span.set("punch.input.errors", rejection.errors.size)
      if rejection.errors.any? { |error| path_params.includes?(error.path.first?) }
        context.span.set("punch.outcome", "not_found")
        return HTTP::Response.problem(:not_found, context, "not_found")
      end
      context.span.set("punch.outcome", "invalid_input")
      locale = context.locale
      HTTP::Response.problem(:unprocessable_entity, context, "invalid_input") do |json|
        json.field "errors" do
          json.array do
            rejection.errors.each do |error|
              json.object do
                json.field "path", error.path
                json.field "code", error.code
                json.field "params", error.params
                locale.error?(error.code, error.params).try { |message| json.field "message", message }
              end
            end
          end
        end
      end
    end

    # Whether a Command's result is a failure: a rejection, a violation, a
    # missing actor, or a type whose status is from 400 on. Its writes roll
    # back, so a refused Command changes nothing.
    #
    # Also checks at compile time that every violation the Command returns
    # has its field in the Command's input; otherwise the Command must map
    # it with `violation.rejection(path...)`.
    def self.failure?(input : I.class, result : T) : Bool forall I, T
      {% begin %}
        {% failures = [] of TypeNode %}
        {% for member in T.union_types %}
          {% status = member.annotation(Punch::Status) %}
          {% if member < Punch::Database::Violation %}
            {% field = member.constant("FIELD") %}
            {% if field.is_a?(StringLiteral) && !I.instance_vars.any? { |ivar| ivar.name.stringify == field } %}
              {% parse_type("::#{I.name.split("::")[0..-2].join("::").id}").resolve.methods.find { |definition| definition.name == "call" }.raise "#{I.name.split("::")[0..-2].join("::").id} returns #{member}, a violation of #{member.constant("CONSTRAINT").id} at the field `#{field.id}`, but its input has no field `#{field.id}`. Return `violation.rejection(...)` with the path of the field it belongs to (lib/punch/docs/queries.md)." %}
            {% end %}
            {% failures << member %}
          {% elsif member == Punch::Rejection || member == Punch::Auth::Unauthenticated || member == Punch::Policy::Refused || (status && status[0] >= 400) %}
            {% failures << member %}
          {% end %}
        {% end %}
        {% if failures.empty? %}
          false
        {% else %}
          result.is_a?({{ failures.map(&.stringify.gsub(::Punch::NAME_STARTS, "::")).join(" | ").id }})
        {% end %}
      {% end %}
    end

    # Compile-time rule: a result of several types declares their statuses
    # (docs/operations.md). A type that declares none answers 200, so a
    # failure that forgot its `@[Punch::Status]` would answer 200, commit
    # the Command's writes, and show as a success in `openapi.json`. The
    # framework's own results (nil, `Punch::Rejection`, violations,
    # `Punch::Auth::Unauthenticated`, `Punch::Policy::Refused`, an HTTP response) have
    # their statuses already and do not count; one type of the app's keeps
    # the default.
    def self.declared_statuses(operation : O.class, result : T) : Nil forall O, T
      {% if T.union? %}
        {% own = T.union_types.reject { |member| member == Nil || member == HTTP::Response || member == Punch::Rejection || member == Punch::Auth::Unauthenticated || member == Punch::Policy::Refused || member < Punch::Database::Violation || member.name.starts_with?("Punch::") } %}
        {% if own.size > 1 %}
          {% for member in own %}
            {% unless member.annotation(Punch::Status) %}
              {% (O.methods.find { |definition| definition.name == "call" } || O).raise "#{O}#call can return #{member}, which has no @[Punch::Status], in a result of #{own.size} types of the app's: a type without one answers 200, so a failure would commit its writes and show as a success. Give every member a status: @[Punch::Status(200)] on the success, a status from 400 on for a failure, or `include Punch::Problem` in the failure (lib/punch/docs/operations.md, lib/punch/docs/openapi.md)." %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    # How *operation* takes idempotency keys: `:none`, `:optional`, or
    # `:required`. A Command takes them when its caller is known (it asks
    # for the actor) or `@[Punch::Idempotency(scope: ...)]` names a scope
    # for anonymous callers; never when it signs in, since the session's
    # cookie cannot be replayed.
    def self.idempotency(operation : O.class) : Symbol forall O
      {% begin %}
        {% declared = O.annotation(Punch::Idempotency) %}
        {% if declared %}
          {% declared.raise "#{O}: @[Punch::Idempotency] is for Commands; a #{O < Punch::Page ? "Page".id : "Query".id} changes nothing, so it is safe to repeat anyway (lib/punch/docs/operations.md)." unless O < Punch::Command %}
          {% unless declared[0] == nil || declared[0] == :required || declared[0] == :optional %}
            {% declared.raise "#{O}: @[Punch::Idempotency] takes :required or :optional, not #{declared[0]}" %}
          {% end %}
          {% unless declared[:scope] == nil || declared[:scope] == :ip || declared[:scope] == :anyone %}
            {% declared.raise "#{O}: @[Punch::Idempotency(scope:)] is :ip or :anyone, not #{declared[:scope]}" %}
          {% end %}
        {% end %}
        {% if O < Punch::Command %}
          {% extras = parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
          {% signs_in = extras.any? { |type| type == Punch::Auth::Authentication || type == Punch::Auth::PasswordCheck } %}
          {% reveals = extras.includes?(Punch::Auth::Reveal) %}
          {% actor = extras.any? { |type| (type.union? ? type.union_types : [type]).any? { |member| member < Punch::Auth::Actor } } %}
          {% if declared && signs_in %}
            {% declared.raise "#{O} signs in or out (Punch::Auth::Authentication or Punch::Auth::PasswordCheck), so it takes no idempotency key: its answer sets a session cookie, which a replay cannot (lib/punch/docs/operations.md)." %}
          {% end %}
          {% if declared && reveals %}
            {% declared.raise "#{O} takes Punch::Auth::Reveal, so it takes no idempotency key: the stored answer would hold the secret it shows once (lib/punch/docs/auth.md)." %}
          {% end %}
          {% if declared && !actor && !declared[:scope] %}
            {% declared.raise "#{O} takes no actor, so its keys need a scope: @[Punch::Idempotency(scope: :ip)] or (scope: :anyone) (lib/punch/docs/operations.md)." %}
          {% end %}
          {% if signs_in || reveals || !(actor || (declared && declared[:scope])) %}
            :none
          {% elsif declared && declared[0] == :required %}
            :required
          {% else %}
            :optional
          {% end %}
        {% else %}
          :none
        {% end %}
      {% end %}
    end

    # A rejection found by the Command itself: 422, like a rejected input.
    def self.render(result : Rejection, context : HTTP::Context) : HTTP::Response
      rejected(result, context)
    end

    # A unique violation from a generated write: 422 with `taken` at its
    # field, like a rejected input.
    def self.render(result : Database::Violation, context : HTTP::Context) : HTTP::Response
      context.span.set("punch.violation", result.constraint)
      rejected(result.rejection, context)
    end

    # 401, with the challenge RFC 9110 requires.
    def self.render(result : Auth::Unauthenticated, context : HTTP::Context) : HTTP::Response
      Auth.unauthenticated(context)
    end

    # The policy said no: 403 or 404.
    def self.render(result : Policy::Refused, context : HTTP::Context) : HTTP::Response
      context.span.set("punch.outcome", result.code)
      HTTP::Response.problem(result.status, context, result.code)
    end

    # A result without content: 204.
    def self.render(result : Nil, context : HTTP::Context) : HTTP::Response
      HTTP::Response.new(:no_content)
    end

    # A result type's status comes from `@[Punch::Status(code)]`, 200 by
    # default. Below 400 the result is the JSON body; from 400 on it is a
    # problem whose `code` is the type's name in snake_case and whose
    # extension members are the type's JSON fields.
    def self.render(result : T, context : HTTP::Context) : HTTP::Response forall T
      {% if T.union? %}
        # A free variable binds the whole union; render each member on its own.
        case result
        {% for member in T.union_types %}
          in {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then render(result, context)
        {% end %}
        end
      {% else %}
        {% status_annotation = T.annotation(Punch::Status) %}
        {% status = status_annotation ? status_annotation[0] : 200 %}
        {% unless status.is_a?(NumberLiteral) && status >= 200 && status <= 599 %}
          {% status_annotation.raise "#{T}: @[Punch::Status] takes a status from 200 to 599, not #{status}" %}
        {% end %}
        context.span.set("punch.outcome", {{ ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) }})
        {% if status < 400 && T < Punch::HTTP::Versioned %}
          {% status_annotation.raise "#{T} includes Punch::HTTP::Versioned, so its status must be 200, not #{status}: only a 200 can become a 304." unless status == 200 %}
          HTTP::Conditional.respond(context, HTTP::Conditional.etag({{ T.name.stringify }}, result.version, context.principal.try(&.user_id))) do
            HTTP::Response.json(:ok, result.to_json)
          end
        {% elsif status < 400 %}
          HTTP::Response.json(::HTTP::Status.new({{ status }}), result.to_json)
        {% else %}
          {% for ivar in T.instance_vars %}
            {% field = ivar.annotation(JSON::Field) %}
            {% key = (field && field[:key]) || ivar.name.stringify %}
            {% if PROBLEM_MEMBERS.includes?(key) %}
              {% status_annotation.raise "#{T}##{ivar.name}: `#{key.id}` is a Problem Details member (RFC 9457); rename the field or its JSON key" %}
            {% end %}
          {% end %}
          {% if T.instance_vars.empty? %}
            HTTP::Response.problem(::HTTP::Status.new({{ status }}), context, {{ ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) }})
          {% else %}
            problem(::HTTP::Status.new({{ status }}), context, {{ ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) }}, result.to_json)
          {% end %}
        {% end %}
      {% end %}
    end

    # A failure result with fields: they are the problem's extension
    # members, and the scalar ones fill in its message (`%{state}`).
    def self.problem(status : ::HTTP::Status, context : HTTP::Context, code : String, members : String) : HTTP::Response
      fields = JSON.parse(members).as_h
      params = {} of String => Invalid::Param
      fields.each do |key, value|
        raw = value.raw

        case raw
        when String, Int64, Float64, Bool then params[key] = raw
        end
      end
      HTTP::Response.problem(status, context, code, params) do |json|
        fields.each { |key, value| json.field key, value }
      end
    end

    {% if flag?(:punch_openapi) %}
      # The OpenAPI build (`punch openapi`) only derives the document and
      # never serves a request, so its routes skip the endpoints: parsing,
      # calling, rendering, and tracing per operation would cost compiler
      # memory at the edge of the budget for nothing.
      OPENAPI_HANDLER = ->(context : HTTP::Context, _params : Hash(String, String), _database : Database) {
        HTTP::Response.problem(:not_implemented, context)
      }
    {% end %}

    private def self.derive : Array(Route)
      {% begin %}
        {% seen = {} of String => String %}
        {% rows = [] of Nil %}
        {% for op in Punch::Operation.all_subclasses.reject(&.abstract?) %}
          {% anchor = op.methods.find { |definition| definition.name == "call" } || op.methods.first || op.annotations.first || op %}
          {% input = op.has_constant?("Input") ? parse_type("::#{op}::Input").resolve : nil %}
          {% unless input && input < Punch::Input %}
            {% anchor.raise "#{op} has no Input. Declare `struct Input; include Punch::Input; end` inside it, empty if the operation takes nothing." %}
          {% end %}
          {% anchor.raise "#{op} has no `call` method." unless op.has_method?("call") %}
          {% command = op < Punch::Command %}
          {% page = op < Punch::Page %}
          {% handle = command ? "Punch::Writer" : "Punch::Reader" %}
          {% for method in op.methods.select { |method| method.name == "call" } %}
            {% restriction = method.args[1] && method.args[1].restriction %}
            {% if restriction && restriction.resolve.stringify != handle %}
              {% method.raise "#{op} is a #{command ? "Command".id : "Query".id}, so its `call` receives a #{handle.id}, not #{restriction} (lib/punch/docs/operations.md)." %}
            {% end %}
          {% end %}
          {% fields = input.instance_vars.select(&.annotation(Punch::PathParam)).map(&.name.stringify) %}
          {% parts = op.name.split("::") %}
          {% action = parts[-1] %}
          {% namespace = parts[0..-2].map(&.underscore) %}
          {% if page %}
            {% unless action.ends_with?("Page") && action.size > 4 %}
              {% anchor.raise "#{op} is a Page, so its name ends in Page, such as #{action.id}Page." %}
            {% end %}
            {% action = action[0..-5] %}
          {% elsif action.ends_with?("Page") %}
            {% anchor.raise "#{op} ends in Page but is a #{command ? "Command".id : "Query".id}. A page subclasses Punch::Page; rename the operation otherwise." %}
          {% end %}

          {% if route = op.annotation(Punch::Route) %}
            {% method = route[0].upcase %}
            {% unless ["GET", "POST", "PUT", "PATCH", "DELETE"].includes?(method) %}
              {% route.raise "#{op}: @[Punch::Route] method must be GET, POST, PUT, PATCH, or DELETE, not #{route[0]}" %}
            {% end %}
            {% if command && method == "GET" %}
              {% route.raise "#{op} is a Command and cannot answer GET: a GET must not change state (lib/punch/docs/operations.md)." %}
            {% end %}
            {% if !command && method != "GET" %}
              {% route.raise "#{op} is a #{page ? "Page".id : "Query".id} and answers only GET." %}
            {% end %}
            {% route.raise "#{op}: @[Punch::Route] path must start with /, got #{route[1]}" unless route[1].starts_with?("/") %}
            {% segments = route[1] == "/" ? [] of String : route[1][1..-1].split("/") %}
            {% params = segments.select(&.starts_with?(":")).map { |segment| segment[1..-1] } %}
            {% unless params.sort == fields.sort %}
              {% route.raise "#{op}: the path #{route[1].id} has parameters #{params}, but the input's path parameters are #{fields}." %}
            {% end %}
          {% else %}
            {% segments = [] of String %}
            {% placed = [] of String %}
            {% for part in namespace %}
              {% segments << part %}
              {% for field in fields %}
                {% if field.ends_with?("_id") && !placed.includes?(field) %}
                  {% stem = field[0..-4] %}
                  {% plural = stem.ends_with?("y") ? stem[0..-2] + "ies" : (stem.ends_with?("s") || stem.ends_with?("x") || stem.ends_with?("ch") || stem.ends_with?("sh") ? stem + "es" : stem + "s") %}
                  {% if part == stem || part == plural %}
                    {% segments << ":" + field %}
                    {% placed << field %}
                  {% end %}
                {% end %}
              {% end %}
            {% end %}
            {% for field in fields %}
              {% segments << ":" + field unless placed.includes?(field) %}
            {% end %}
            {% if page %}
              {% if action == "Destroy" %}
                {% anchor.raise "#{op}: DestroyPage is not a page name. A page that confirms a deletion has its own name, such as ConfirmDestroyPage." %}
              {% end %}
              {% if action == "Create" %}
                {% segments << "new" %}
              {% elsif action == "Update" %}
                {% segments << "edit" %}
              {% elsif action != "Index" && action != "Show" %}
                {% segments << action.underscore %}
              {% end %}
              {% method = "GET" %}
            {% elsif action == "Index" || action == "Show" %}
              {% anchor.raise "#{op} is a Command, but `#{action.id}` is reserved for Queries (GET)." if command %}
              {% method = "GET" %}
            {% elsif action == "Create" || action == "Update" || action == "Destroy" %}
              {% anchor.raise "#{op} is a Query, but `#{action.id}` is reserved for Commands." unless command %}
              {% method = {"Create" => "POST", "Update" => "PATCH", "Destroy" => "DELETE"}[action] %}
            {% else %}
              {% segments << action.underscore %}
              {% method = command ? "POST" : "GET" %}
            {% end %}
          {% end %}

          {% template = "/" + segments.join("/") %}
          {% key = (page ? "page " : "") + method + " /" + segments.map { |segment| segment.starts_with?(":") ? ":" : segment }.join("/") %}
          {% if seen[key] %}
            {% anchor.raise "Route collision: #{op} and #{seen[key].id} both answer #{method.id} #{template.id}. Rename one, or give one @[Punch::Route]." %}
          {% end %}
          {% seen[key] = op.stringify %}
          {% kind = command ? "Command" : (page ? "Page" : "Query") %}
          {% holder = nil %}
          {% if command %}
            {% pages = Punch::Page.all_subclasses.reject(&.abstract?) %}
            {% claimed = pages.select { |candidate| candidate.has_constant?("PunchForms") && parse_type("::#{candidate}::PunchForms").resolve.type_vars.includes?(op) } %}
            {% if claimed.size > 1 %}
              {% anchor.raise "#{op}: #{claimed.map(&.stringify).join(" and ").id} both hold its form (@[Punch::Forms]). One page holds a Command's form." %}
            {% end %}
            {% holder = claimed[0] || pages.find { |candidate| candidate.name.stringify == "#{op}Page" } %}
            {% if holder %}
              {% holder_input = parse_type("::#{holder}::Input").resolve %}
              {% holder_anchor = holder.methods.find { |definition| definition.name == "call" } || holder.methods.first || holder %}
              {% for field in holder_input.instance_vars %}
                {% if field.annotation(Punch::PathParam) %}
                  {% match = input.instance_vars.find { |own| own.name == field.name && own.annotation(Punch::PathParam) } %}
                  {% unless match && match.type == field.type %}
                    {% holder_anchor.raise "#{holder} holds the form of #{op}, so it is shown again with the errors when #{op} refuses a submission, from #{op}'s path. Its path parameter `#{field.name}` (#{field.type}) is not one of #{op}'s." %}
                  {% end %}
                {% elsif !(field.type.nilable? || field.has_default_value?) %}
                  {% holder_anchor.raise "#{holder} holds the form of #{op}, so it is shown again with the errors when #{op} refuses a submission, from #{op}'s path alone. Its required field `#{field.name}` cannot be filled from there; make it optional." %}
                {% end %}
              {% end %}
            {% end %}
          {% elsif page && op.has_constant?("PunchForms") %}
            {% for listed in parse_type("::#{op}::PunchForms").resolve.type_vars %}
              {% unless listed < Punch::Command %}
                {% anchor.raise "#{op}: @[Punch::Forms] lists the Commands whose forms the page holds; #{listed} is not a Command." %}
              {% end %}
            {% end %}
          {% end %}
          {% extras = parse_type("::#{op}::PunchCallExtras").resolve.type_vars %}
          {% actor_kind = extras.any? { |type| !type.union? && type < Punch::Auth::Actor } ? "required" : (extras.any? { |type| type.union? && type.union_types.any? { |member| member < Punch::Auth::Actor } } ? "optional" : "none") %}
          {% exempt = op.annotation(Punch::RateLimitExempt) %}
          {% policy = op.has_constant?("PunchPolicy") ? parse_type("::#{op}::PunchPolicy").resolve.stringify : nil %}
          {% unless policy || op.annotation(Punch::Public) %}
            {% anchor.raise "#{op} needs a policy, @[Punch::Authorize(Policy)], or @[Punch::Public]: an operation without either would run for anyone (lib/punch/docs/authorization.md)." %}
          {% end %}
          {% if command && actor_kind != "required" && op.annotations(Punch::RateLimit).empty? && !exempt %}
            {% anchor.raise "#{op} is a Command that runs without a signed-in user, so it needs a rate limit, @[Punch::RateLimit(5, per: 1.minute, by: :ip)], or @[Punch::RateLimitExempt(\"reason\")] (lib/punch/docs/rate-limits.md)." %}
          {% end %}
          {% readable = op.annotation(Punch::AgentReadable) %}
          {% if readable && !page %}
            {% anchor.raise "#{op}: @[Punch::AgentReadable] marks pages that agents read as markdown; #{op} is not a page. A Query already serves programs JSON." %}
          {% end %}
          {% entry = !!(readable && readable[:entry]) %}
          {% if entry %}
            {% unless readable[:entry] == true %}
              {% readable.raise "#{op}: @[Punch::AgentReadable(entry: true)] lists the page in /llms.txt; entry takes true, not #{readable[:entry]}." %}
            {% end %}
            {% if op.annotation(Punch::Unlisted) %}
              {% anchor.raise "#{op} is @[Punch::Unlisted], so it cannot be an entry point in /llms.txt. Remove one of the two." %}
            {% end %}
            {% for field in input.instance_vars %}
              {% unless !field.annotation(Punch::PathParam) && (field.type.nilable? || field.has_default_value?) %}
                {% anchor.raise "#{op} is an entry point in /llms.txt, so an agent opens it from its path alone. Its #{field.annotation(Punch::PathParam) ? "path parameter".id : "required field".id} `#{field.name}` cannot be filled from there; make it optional, or drop entry: true." %}
              {% end %}
            {% end %}
          {% end %}
          {% rows << {op, method, template, segments, parts.map(&.underscore).join("."), kind, holder, actor_kind, exempt ? exempt[0] : nil, policy, !!op.annotation(Punch::Public), !!op.annotation(Punch::Unlisted), !!readable, entry} %}
        {% end %}

        [
          {% for row in rows %}
            Route.new({{ row[1] }}, {{ row[2] }}, [{{ row[3].splat }}] of String, {{ row[0].stringify }}, {{ row[4] }}, Kind::{{ row[5].id }},
              {% if flag?(:punch_openapi) %}
                OPENAPI_HANDLER,
              {% else %}
                ->(context : HTTP::Context, params : Hash(String, String), database : Database) {
                  Punch::Routing.endpoint({{ row[0].stringify.gsub(::Punch::NAME_STARTS, "::").id }}, context, params, database)
                },
              {% end %}
              {{ row[6] ? row[6].stringify : nil }},
              {% if row[0].has_constant?("PUNCH_RATE_LIMITS") %} {{ row[0].stringify.gsub(::Punch::NAME_STARTS, "::").id }}::PUNCH_RATE_LIMITS.to_a {% else %} [] of RateLimits::Limiter {% end %},
              {{ row[7] }}, {{ row[8] }}, {{ row[9] }}, {{ row[10] }}, {{ row[11] }}, {{ row[12] }}, {{ row[13] }}, {{ row[0].has_constant?("PunchLiveEvents") }}),
          {% end %}
        ] of Route
      {% end %}
    end
  end

  # Finds the route for a request and runs it. Literal segments win over
  # parameters, so `/invoices/export` and `/invoices/:invoice_id` coexist.
  #
  # Where a page and a Query share a path, `Accept` picks: HTML when the
  # client prefers it (browsers do), JSON otherwise, with `Vary: Accept`.
  # Routing errors are pages for clients that prefer HTML.
  class Routing::Router
    # What `Accept` chooses between, the default first.
    OFFERS = ["application/json", "text/html"]
    # The same where the page is agent-readable, and for an agent-readable
    # page without a Query on its path.
    AGENT_OFFERS      = ["application/json", "text/html", "text/markdown"]
    AGENT_PAGE_OFFERS = ["text/html", "text/markdown"]

    private class Node
      getter literals = {} of String => Node
      property parameter : Node?
      # JSON routes by method.
      getter routes = {} of String => Routing::Route
      property page : Routing::Route?

      def empty? : Bool
        routes.empty? && page.nil?
      end
    end

    @root = Node.new

    # With *openapi* (`Punch.openapi_document`), `GET /openapi.json` serves
    # that document.
    # Agent-readable pages listed in `/llms.txt`.
    @entries : Array(Routing::Route)

    def initialize(@database : Database, routes : Array(Routing::Route) = Routing.routes, @openapi : String? = nil)
      @entries = routes.select(&.entry).sort_by!(&.template)
      routes.each do |route|
        if route.template.starts_with?(Assets::PREFIX)
          raise ArgumentError.new("#{route.operation} is routed below #{Assets::PREFIX}, which belongs to assets; rename it or give it @[Punch::Route]")
        end
        node = route.segments.reduce(@root) do |current, segment|
          if segment.starts_with?(':')
            current.parameter ||= Node.new
          else
            current.literals[segment] ||= Node.new
          end
        end
        if route.kind.page?
          node.page = route
        else
          node.routes[route.method] = route
        end
      end
    end

    def call(context : HTTP::Context) : HTTP::Response
      request = context.request
      path = request.path
      if response = fixed(context)
        return response
      end
      return not_found(context) unless path.starts_with?('/')

      suffixed = suffixed?(context)
      path = request.path
      segments = path == "/" ? [] of String : path[1..].split('/').map { |segment| URI.decode(segment) }
      node = find(@root, segments, 0) || return not_found(context)
      method = method(request)
      if suffixed
        route, negotiated = by_suffix(node, method, context), false
        return not_found(context) unless route
      else
        route, negotiated = choose(node, method, context)
      end
      return method_not_allowed(context, node) unless route

      trace(context.span, request.method == "HEAD" ? "HEAD" : method, route, context.markdown?)
      return cross_origin(context) unless HTTP::CrossOrigin.allowed?(request, context.config.trusted_origins)

      params = {} of String => String
      route.segments.each_with_index do |segment, index|
        params[segment[1..]] = segments[index] if segment.starts_with?(':')
      end
      response = RateLimits.apply(with_cookies(route.handler.call(context, params, @database), context), context)
      negotiated ? HTTP::Accept.vary(response) : response
    end

    # What is served without an operation: assets, `openapi.json`,
    # `/llms.txt` where pages are entry points for agents, and uploads'
    # check and local files (`docs/uploads.md`).
    private def fixed(context : HTTP::Context) : HTTP::Response?
      request = context.request
      path = request.path
      return Upload::Endpoint.respond(context, @database) if path.starts_with?(Upload::PREFIX)
      return unless request.method.in?("GET", "HEAD")

      if path.starts_with?(Assets::PREFIX)
        Assets.respond(context) || not_found(context)
      elsif (document = @openapi) && path == "/openapi.json"
        HTTP::Response.json(:ok, document)
      elsif path == LLMs::PATH && !@entries.empty?
        context.span.set("punch.surface", "markdown")
        response = HTTP::Response.new(:ok, LLMs.render(@entries, context.locale, openapi: !@openapi.nil?),
          ::HTTP::Headers{"Content-Type" => LLMs::CONTENT_TYPE})
        response.headers["Vary"] = "Accept-Language" if context.negotiated?
        response
      end
    end

    # Whether the path asks for markdown by its suffix:
    # `/billing/invoices/42.md` is `/billing/invoices/42` as markdown, for
    # agents that send no `Accept`. The request continues without the
    # suffix, so forms, idempotency keys, and traces see the page's path.
    private def suffixed?(context : HTTP::Context) : Bool
      request = context.request
      path = request.path
      return false unless path.ends_with?(Routing::MARKDOWN_SUFFIX) && path.size > Routing::MARKDOWN_SUFFIX.size + 1

      request.path = path == Routing::MARKDOWN_INDEX ? "/" : path.rchop(Routing::MARKDOWN_SUFFIX)
      context.markdown = true
      true
    end

    # The route behind a `.md` URL: an agent-readable page, or a Command
    # whose form a page holds, sent as a form (an action block). Anything
    # else has no markdown, so the URL is not found.
    private def by_suffix(node : Node, method : String, context : HTTP::Context) : Routing::Route?
      if method == "GET"
        node.page.try { |page| page if page.agent_readable }
      elsif (route = node.routes[method]?) && route.kind.command? && route.form_page && form?(context.request)
        route
      end
    end

    private def form?(request : ::HTTP::Request) : Bool
      request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) == "application/x-www-form-urlencoded"
    end

    # The method to route by: `GET` for `HEAD`, and for a form the method
    # its action names. A form can only `POST`; a form for a `PATCH`,
    # `PUT`, or `DELETE` Command says so in its action, `?_method=PATCH`
    # (`Action#url`). Honoured for form bodies only, never for JSON.
    private def method(request : ::HTTP::Request) : String
      return "GET" if request.method == "HEAD"
      return request.method unless request.method == "POST"
      return "POST" unless request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) == "application/x-www-form-urlencoded"

      method = request.query_params["_method"]?.try(&.upcase)
      method.in?("PATCH", "PUT", "DELETE") ? method.to_s : "POST"
    end

    private def trace(span : Trace::Span, method : String, route : Routing::Route, markdown : Bool) : Nil
      return unless span.recording?

      span.name = "#{method} #{route.template}"
      span.set("http.route", route.template)
      span.set("punch.operation", route.operation)
      span.set("punch.surface", markdown ? "markdown" : route.kind.surface)
    end

    # The route for *method*, and whether `Accept` chose it: between a
    # page and a Query, and between HTML and markdown for a page agents
    # read, which sets `HTTP::Context#markdown?`. Any other page answers
    # HTML whatever the client asks for: a server may ignore `Accept`.
    private def choose(node : Node, method : String, context : HTTP::Context) : {Routing::Route?, Bool}
      page = node.page if method == "GET"
      return command(node.routes[method]?, context) unless page

      # A live page's stream is the page's, whatever shares its path.
      return {page, true} if Live.requested?(context)

      query = node.routes["GET"]?
      if page.agent_readable
        preferred = HTTP::Accept.preferred(context.request.headers["Accept"]?, query ? AGENT_OFFERS : AGENT_PAGE_OFFERS)
        return {query, true} if query && preferred == "application/json"

        context.markdown = preferred == "text/markdown"
        context.markdown_alternate = true
        return {page, true}
      end
      return {page, false} unless query

      {html?(context) ? page : query, true}
    end

    # A form sent to a Command by an agent that reads markdown (an action
    # block) is answered as a browser's form, in markdown: the page holding
    # the form shows the refusal. Whether it is, `Accept` chooses.
    private def command(route : Routing::Route?, context : HTTP::Context) : {Routing::Route?, Bool}
      return {route, false} unless route && route.form_page && route.kind.command?

      request = context.request
      return {route, false} unless form?(request)

      context.markdown = HTTP::Accept.preferred(request.headers["Accept"]?, AGENT_PAGE_OFFERS) == "text/markdown"
      {route, true}
    end

    # Whether the client prefers HTML to JSON.
    private def html?(context : HTTP::Context) : Bool
      HTTP::Accept.preferred(context.request.headers["Accept"]?, OFFERS) == "text/html"
    end

    # A routing problem as a page for clients that prefer HTML, as Problem
    # Details otherwise.
    private def problem(context : HTTP::Context, status : ::HTTP::Status, code : String = status.to_s.downcase) : HTTP::Response
      HTTP::Accept.vary(html?(context) || context.markdown? ? Pages.problem(status, code, context) : HTTP::Response.problem(status, context, code))
    end

    # 403 for a Command sent from another site's page.
    private def cross_origin(context : HTTP::Context) : HTTP::Response
      context.span.set("punch.outcome", "cross_origin_request")
      problem(context, :forbidden, "cross_origin_request")
    end

    private def with_cookies(response : HTTP::Response, context : HTTP::Context) : HTTP::Response
      context.cookies.each { |cookie| response.headers.add("Set-Cookie", cookie) } if context.cookies?
      response
    end

    private def find(node : Node, segments : Array(String), index : Int32) : Node?
      return (node.empty? ? nil : node) if index == segments.size

      segment = segments[index]
      if (literal = node.literals[segment]?) && (found = find(literal, segments, index + 1))
        return found
      end
      return if segment.empty?

      (parameter = node.parameter) ? find(parameter, segments, index + 1) : nil
    end

    private def not_found(context : HTTP::Context) : HTTP::Response
      problem(context, :not_found)
    end

    private def method_not_allowed(context : HTTP::Context, node : Node) : HTTP::Response
      allowed = node.routes.keys
      allowed << "GET" if node.page && !allowed.includes?("GET")
      allowed << "HEAD" if allowed.includes?("GET")
      response = problem(context, :method_not_allowed)
      response.headers["Allow"] = allowed.sort.join(", ")
      response
    end
  end
end
