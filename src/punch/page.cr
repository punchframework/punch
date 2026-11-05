require "./operation"
require "./view"

module Punch
  # Marks a page that agents may read as markdown:
  # `@[Punch::AgentReadable]`. Nothing reaches the markdown surface without
  # it. The page's components render through a plain `View` for it, so one
  # that writes raw HTML outside a chrome block does not compile
  # (docs/views.md, "Pages agents read").
  annotation AgentReadable
  end

  # A page for people: an endpoint that reads, composes operations, and
  # answers `GET` with HTML rendered from components.
  #
  # ```
  # module Billing::Invoices
  #   struct ShowPage < Punch::Page
  #     alias Input = Show::Input
  #
  #     def call(input : Input, db : Punch::Reader, actor : Actor) : DetailView | NotFound
  #       case detail = Show.new.call(input, db, actor)
  #       in NotFound then detail
  #       in Detail   then DetailView.new(detail)
  #       end
  #     end
  #   end
  # end
  # # GET /billing/invoices/:invoice_id, as HTML
  # ```
  #
  # A page takes a `Reader`, its input from the path and query string, and
  # the actor like any operation (docs/auth.md). Its name ends in `Page`;
  # without the suffix, the route follows the three rules of
  # docs/operations.md, except that `CreatePage` answers `/new` and
  # `UpdatePage` `/:id/edit`, the pages that hold their Command's form.
  #
  # A page and a Query may share a path: browsers get the page, programs
  # the JSON (`Accept`, `Vary: Accept`). Pages are not in `openapi.json`.
  #
  # `call` returns components (`Punch::Component`), rendered as HTML with
  # the status of their `@[Punch::Status]` (200 by default), or results
  # from 400 on, rendered as Punch's problem page.
  abstract struct Page < Operation
    # Where a browser goes after a Command whose form this page holds
    # succeeded: overload it per result type. `nil`, the default, means
    # this page again, at the Command's path parameters.
    #
    # ```
    # def self.redirect(result : Created) : Punch::Href
    #   ShowPage.href(customer_id: result.customer.id)
    # end
    # ```
    def self.redirect(result) : Href?
    end

    # What Turbo changes on the page after a Command whose form this page
    # holds succeeded, instead of following the redirect: overload it per
    # result type. Answered only to a request that names
    # `text/vnd.turbo-stream.html` in `Accept`, as Turbo does for forms;
    # `nil`, the default, and every other client get the redirect.
    #
    # ```
    # def self.stream(result : Created) : Punch::TurboStream?
    #   Punch::TurboStream.build { |stream| stream.prepend "customers", CustomerRow.new(result.customer) }
    # end
    # ```
    #
    # The stream renders after the Command, with this page's actor asking
    # the policies of forms and links in it.
    def self.stream(result) : TurboStream?
    end

    # This page at the path parameters of *input*, without a query: where a
    # GET form sends what it shows (`View#filter_form`).
    # :nodoc:
    def self.path_of(input : Input) : Href
      {% begin %}
        href({% for field in parse_type("::#{@type}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)) %}{{ field.name }}: input.{{ field.name }}, {% end %})
      {% end %}
    end

    # A link to this page, checked at compile time: every path parameter,
    # any query parameter of the input, each of its field's type.
    #
    # ```
    # Invoices::ShowPage.href(invoice_id: id)  # => /billing/invoices/42
    # Invoices::IndexPage.href(after: last.id) # => /billing/invoices?after=42
    # ```
    def self.href(**params : **T) : Href forall T
      {% begin %}
        {% input = parse_type("::#{@type}::Input").resolve %}
        {% fields = input.instance_vars %}
        {% names = fields.map(&.name.stringify) %}
        {% for key in T.keys %}
          {% raise "#{@type}.href: unknown parameter `#{key}`. Parameters: #{names.empty? ? "none" : names.join(", ").id}" unless names.includes?(key.stringify) %}
        {% end %}
        {% for field in fields %}
          {% given = T[field.name] %}
          {% path_param = field.annotation(Punch::PathParam) %}
          {% optional = !path_param && (field.type.nilable? || field.has_default_value?) %}
          {% if given %}
            {% base = field.type.union_types.reject(&.==(Nil)).first %}
            {% for member in given.union_types %}
              {% if member == Nil %}
                {% raise "#{@type}.href: `#{field.name}` is required and cannot be nil" unless optional %}
              {% else %}
                {% raise "#{@type}.href: `#{field.name}` must be #{base}, not #{given}" unless member <= base %}
              {% end %}
            {% end %}
          {% elsif !optional %}
            {% raise "#{@type}.href: missing #{path_param ? "path parameter".id : "parameter".id} `#{field.name}` (#{field.type})" %}
          {% end %}
        {% end %}
        %path = Punch::Routing.fill(Punch::Routing.template({{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}), {
          {% for field in fields.select(&.annotation(Punch::PathParam)) %}
            {{ field.name.stringify }} => Punch::Routing.segment(params[{{ field.name.symbolize }}]),
          {% end %}
        } of String => String)
        %permit = ->(authorizer : Punch::Policy::Authorizer) {
          Punch::Grant({{ @type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}).permitted?(authorizer{% for field in fields.select(&.annotation(Punch::PathParam)) %}, {{ field.name }}: params[{{ field.name.symbolize }}]{% end %})
        }
        {% query = fields.reject(&.annotation(Punch::PathParam)).select { |field| T[field.name] } %}
        {% if query.empty? %}
          Punch::Href.new(%path, {{ @type.stringify }}, permit: %permit)
        {% else %}
          %query = URI::Params.build do |builder|
            {% for field in query %}
              Punch::Pages.encode_param(builder, {{ field.name.stringify }}, params[{{ field.name.symbolize }}])
            {% end %}
          end
          Punch::Href.new(%query.empty? ? %path : "#{%path}?#{%query}", {{ @type.stringify }}, permit: %permit)
        {% end %}
      {% end %}
    end
  end

  # Turns a page's results into HTML responses.
  module Pages
    # :nodoc:
    def self.encode_param(builder : URI::Params::Builder, name : String, value : Nil) : Nil
    end

    # :nodoc:
    def self.encode_param(builder : URI::Params::Builder, name : String, value : Punch::Input) : Nil
      value.__punch_encode(builder, name)
    end

    # :nodoc:
    def self.encode_param(builder : URI::Params::Builder, name : String, value : Array) : Nil
      value.each { |item| builder.add(name, Routing.segment(item)) }
    end

    # :nodoc:
    def self.encode_param(builder : URI::Params::Builder, name : String, value) : Nil
      builder.add(name, Routing.segment(value))
    end

    # Marks the markdown rendering of an agent-readable page, for
    # `respond`. A type, not a flag, so that only such pages compile it.
    # :nodoc:
    struct Markdown
    end

    # The response to a page's result: a component as HTML, or as markdown
    # with *format* `Markdown`; anything else (a result from 400 on) as the
    # problem page.
    def self.respond(result : T, context : HTTP::Context, authorizer : Policy::Authorizer? = nil, format : F.class = Nil) : HTTP::Response forall T, F
      {% if T.union? %}
        case result
        {% for member in T.union_types %}
          in {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then respond(result, context, authorizer, format)
        {% end %}
        end
      {% elsif T == Punch::Auth::Unauthenticated %}
        unauthenticated(context)
      {% elsif T == Punch::Policy::Refused %}
        context.span.set("punch.outcome", result.code)
        problem(result.status, result.code, context)
      {% elsif T == Nil %}
        {% raise "A page answers with a component, not nil. Return a component (include Punch::Component), or a result with @[Punch::Status] from 400 on." %}
      {% else %}
        {% status_annotation = T.annotation(Punch::Status) %}
        {% status = status_annotation ? status_annotation[0] : 200 %}
        {% unless status.is_a?(NumberLiteral) && status >= 200 && status <= 599 %}
          {% status_annotation.raise "#{T}: @[Punch::Status] takes a status from 200 to 599, not #{status}" %}
        {% end %}
        {% code = ((T.type_vars.empty? && T.has_constant?("PROBLEM_CODE")) ? T.constant("PROBLEM_CODE") : T.name(generic_args: false).split("::").last.underscore) %}
        # A refused form shown again keeps the refusal as the outcome.
        context.span.set("punch.outcome", {{ code }}) unless context.submission
        {% if T < Punch::Component && F == Punch::Pages::Markdown %}
          markdown(::HTTP::Status.new({{ status }}), result, context, authorizer)
        {% elsif T < Punch::Component %}
          html(::HTTP::Status.new({{ status }}), result, context, authorizer)
        {% elsif status >= 400 %}
          problem(::HTTP::Status.new({{ status }}), {{ code }}, context)
        {% else %}
          {% raise "#{T} is a page's result, but not a component and not a failure. A page renders components (include Punch::Component); data for programs belongs to a Query." %}
        {% end %}
      {% end %}
    end

    # Renders *component* with *status*, in a `render` span.
    #
    # While a refused form is shown again (`context.submission`), the page
    # answers with the refusal's status: Turbo renders only a 4xx or 5xx
    # answer to a form.
    def self.html(status : ::HTTP::Status, component : Component, context : HTTP::Context, authorizer : Policy::Authorizer? = nil) : HTTP::Response
      submission = context.submission
      status = submission.status if submission && status.code < 400
      span = context.span.child("render")
      span.set("punch.view", component.class.name) if span.recording?
      html = begin
        # An agent-readable page names its markdown, at its `.md` URL.
        alternate = Routing.markdown_url(context.request.resource) if context.markdown_alternate?
        HTMLView.render(component, submission, authorizer, context.locale, alternate: alternate, live: live_source(context))
      ensure
        if authorizer && span.recording? && authorizer.hidden > 0
          span.set("punch.authz.hidden", authorizer.hidden)
        end
        span.finish
      end
      HTTP::Response.html(status, html)
    end

    # Where a live page's stream is opened: the page's URL as requested,
    # or, for a page shown again after a refused form, its path.
    private def self.live_source(context : HTTP::Context) : String?
      position = context.live_position || return
      request = context.request
      resource = request.method == "GET" ? request.resource : context.live_path || return
      Live.source(resource, position)
    end

    # Renders *component* as markdown with *status*, in a `render` span.
    def self.markdown(status : ::HTTP::Status, component : Component, context : HTTP::Context, authorizer : Policy::Authorizer? = nil) : HTTP::Response
      submission = context.submission
      status = submission.status if submission && status.code < 400
      span = context.span.child("render")
      span.set("punch.view", component.class.name) if span.recording?
      markdown = begin
        View.markdown(component, authorizer, context.locale, submission)
      ensure
        if authorizer && span.recording? && authorizer.hidden > 0
          span.set("punch.authz.hidden", authorizer.hidden)
        end
        span.finish
      end
      HTTP::Response.markdown(status, markdown)
    end

    # Punch's problem page: the status, the problem's message and code, and
    # the request ID, with the field errors of a rejection, in the
    # request's locale. *params* fill in the message. As markdown for an
    # agent reading a page (`HTTP::Context#markdown?`).
    def self.problem(status : ::HTTP::Status, code : String, context : HTTP::Context,
                     errors : Array(Rejection::FieldError) = [] of Rejection::FieldError, *,
                     params : Hash(String, Invalid::Param) = {} of String => Invalid::Param) : HTTP::Response
      page = Pages::ProblemPage.new(status, code, context.request_id, errors, params)
      if context.markdown?
        HTTP::Response.markdown(status, View.markdown(page, locale: context.locale))
      else
        HTTP::Response.html(status, HTMLView.render(page, locale: context.locale))
      end
    end

    # An input that does not parse. A path parameter that does not parse
    # names no page, so the answer is 404; otherwise 422 with the errors.
    def self.rejected(rejection : Rejection, context : HTTP::Context, path_params : Array(String)) : HTTP::Response
      context.span.set("punch.input.errors", rejection.errors.size)
      if rejection.errors.any? { |error| path_params.includes?(error.path.first?) }
        context.span.set("punch.outcome", "not_found")
        return problem(:not_found, "not_found", context)
      end
      context.span.set("punch.outcome", "invalid_input")
      problem(:unprocessable_entity, "invalid_input", context, rejection.errors)
    end

    # The app's sign-in page, where a browser that is not signed in goes
    # instead of the 401 page (docs/auth.md). Set it once at boot:
    #
    # ```
    # Punch::Pages.sign_in = Accounts::SignInPage.href
    # ```
    class_property sign_in : Href? = nil

    # A page or form that needs a signed-in user, without one: `303` to
    # the sign-in page when the app has one, else 401 as a page with the
    # challenge RFC 9110 requires. A request that presented a bearer token
    # meant to authenticate with it, so it gets the 401 either way.
    #
    # An agent reading markdown gets the 401: it signs in with a token,
    # not with the sign-in page's form.
    def self.unauthenticated(context : HTTP::Context) : HTTP::Response
      context.span.set("punch.outcome", "unauthenticated")
      if (target = sign_in) && !context.request.headers.has_key?("Authorization") && !context.markdown?
        response = HTTP::Response.html(:see_other, HTMLView.render(Pages::SignInLink.new(target), locale: context.locale))
        response.headers["Location"] = target.url
        return response
      end
      response = problem(:unauthorized, "unauthenticated", context)
      response.headers["WWW-Authenticate"] = Auth.challenge(context)
      response
    end
  end

  # The body of the redirect to the sign-in page, for clients that do not
  # follow it.
  struct Pages::SignInLink
    include Component

    def initialize(@target : Href)
    end

    def view(v : View) : Nil
      text = v.locale.translate?("punch.page.sign_in") || "Sign in"
      v.document(text) do
        v.main(class: "punch-problem") { v.p { v.a text, href: @target } }
      end
    end
  end

  # The page Punch shows for a problem: status, the problem's message and
  # code, request ID, and the field errors of a rejection, in the view's
  # locale.
  struct Pages::ProblemPage
    include Component

    def initialize(@status : ::HTTP::Status, @code : String, @request_id : String?, @errors : Array(Rejection::FieldError),
                   @params : Hash(String, Invalid::Param) = {} of String => Invalid::Param)
    end

    def view(v : View) : Nil
      locale = v.locale
      title = @status.description || @status.code.to_s
      v.document("#{@status.code} #{title}") do
        v.main(class: "punch-problem") do
          v.h1 title
          locale.problem?(@code, @params).try { |message| v.p message }
          v.p do
            v.text "#{locale.translate?("punch.page.problem") || "Problem"}: "
            v.code @code
          end
          unless @errors.empty?
            v.ul do
              @errors.each do |error|
                v.li do
                  v.code error.path.join('.')
                  v.text ": "
                  if message = locale.error?(error.code, error.params)
                    v.text "#{message} "
                  end
                  v.code error.code
                end
              end
            end
          end
          if id = @request_id
            v.p do
              v.text "#{locale.translate?("punch.page.request_id") || "Request ID"}: "
              v.code id
            end
          end
        end
      end
    end
  end
end
