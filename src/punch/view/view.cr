require "./safe_html"
require "./href"
require "./tag"
require "./backend"
require "./tree_backend"
require "./text_backend"
require "./markdown_backend"
require "./action_block"
require "./component"
require "./form"
require "./stream"

module Punch
  # What components write to: HTML element names, with the element's meaning
  # known, so that one component tree can be written as HTML now and as
  # markdown later.
  #
  # ```
  # v.h1 "Invoices"
  # v.p do
  #   v.text "Total: "
  #   v.strong total
  # end
  # v.ul(class: "lines") do
  #   lines.each { |line| v.li line.description }
  # end
  # v.a "Next page", href: Invoices::IndexPage.href(after: last_id)
  # ```
  #
  # Every element takes its text or a block, and attributes as named
  # arguments: `class`, `id`, `data: {turbo_frame: "lines"}` (written
  # `data-turbo-frame`), `aria: {label: "Close"}`. An underscore in a name
  # becomes a hyphen. Text and attribute values are always escaped.
  #
  # Checked at compile time: a link takes a `Punch::Href`, never a string;
  # no event handler (`on…`) or inline style, which the
  # Content-Security-Policy would block anyway; attribute values are
  # strings, numbers, booleans (`true` writes the bare name, `false` and
  # `nil` leave it out), `Time` (RFC 3339), or a list of class names.
  #
  # Checked while rendering, raising `NestingError`: elements nest as in
  # HTML, narrowed to what markdown can express. A paragraph or heading
  # holds only text and phrasing elements, a list only `li`, a table only
  # `caption`, `thead`, `tbody`, and `tfoot`, and so on (`ELEMENTS`).
  class View
    # An element where it cannot be: a bug in the component, found by any
    # spec that renders it.
    class NestingError < Exception
    end

    # Attributes holding a URL, which take only a `Punch::Href`.
    URL_ATTRIBUTES = %w[href src action formaction cite poster ping background]

    # What a view and the views it hands to `chrome` share.
    # :nodoc:
    class State
      getter stack = [Tag::Fragment]
      property links = 0
      property forms = 0
      property? document = false
      # A refused form being shown again (`Punch::Submissions`).
      getter submission : Submission?
      # Whether a form showed it: the page may no longer hold the form.
      property? submission_shown = false
      # Who is looking, for forms and links that ask their policy; `nil`
      # outside a request, where everything renders.
      getter authorizer : Policy::Authorizer?
      # The language the view renders in.
      getter locale : Locale
      # Rendering a mail (`Punch::Mailer`): no document, no forms.
      getter? mail : Bool

      # The URL of the page's markdown, written in the head of an
      # agent-readable page's HTML.
      getter alternate : String?

      # The URL of a live page's stream, opened at the end of its body
      # (`Punch::Live`).
      getter live : String?

      # Rendering the content of Turbo Stream actions (`Punch::TurboStream`):
      # parts of a page, no document.
      getter? stream : Bool

      def initialize(@submission : Submission? = nil, @authorizer : Policy::Authorizer? = nil, locale : Locale? = nil, *, @mail = false,
                     @alternate : String? = nil, @stream = false, @live : String? = nil)
        @locale = locale || I18n.default
        @stack << Tag::Body if @mail
        @stack << Tag::Template if @stream
      end
    end

    protected getter backend : Backend
    protected getter state : State

    def initialize(@backend : Backend, @state : State = State.new)
    end

    # Renders *component* as markdown, through a plain view: a component
    # that writes raw HTML outside chrome does not compile here. With
    # *authorizer*, forms and links ask their policies; in *locale*, the
    # default locale without one. With *submission*, the form it refused
    # shows the values and errors in its action block.
    def self.markdown(component : Component, authorizer : Policy::Authorizer? = nil, locale : Locale? = nil,
                      submission : Submission? = nil) : String
      backend = MarkdownBackend.new
      state = State.new(submission, authorizer, locale)
      backend.locale = state.locale
      View.new(backend, state).render(component)
      if submission && !state.submission_shown?
        backend.refused = submission.errors.map { |error| FormTarget::Problem.new(Form.name(error.path), Form.message(state.locale, error), error.code) }
      end
      backend.to_s
    end

    # The language this view renders in: the request's. Its formats are
    # `v.locale.date(time)`, `v.locale.money(amount, currency)`, and so on.
    def locale : Locale
      @state.locale
    end

    # The app's typed translations in this view's locale
    # (`v.t.invoices.sent(number: n)`), once the app declares them with
    # `Punch.translations`.
    def t
      @state.locale.t
    end

    {% for name, spec in ELEMENTS %}
      {% tag = "Tag::#{name.id.camelcase}".id %}
      {% if name == :a %}
        # A link to a page (`SomePage.href(...)`) or another site
        # (`Punch::Href.external`). A link to a page the viewer may not
        # open, by its policy, is left out with its content.
        def a(text : String, *, href : Href, **attributes) : Nil
          return unless permitted?(href.permit)
          element({{ tag }}, attributes, href) { @backend.text(text) }
        end

        # :ditto:
        def a(*, href : Href, **attributes, &) : Nil
          return unless permitted?(href.permit)
          element({{ tag }}, attributes, href) { yield }
        end
      {% elsif name == :img %}
        # An image: an asset (`Punch.asset("logo.svg").href`) or another
        # site's. *alt* is required; `""` marks a decorative image.
        def img(*, src : Href, alt : String, **attributes) : Nil
          enter({{ tag }})
          @backend.start({{ tag }})
          @backend.attribute("src", src)
          @backend.attribute("alt", alt)
          write_attributes(attributes)
          @backend.started({{ tag }})
          leave({{ tag }})
        end
      {% elsif spec[1] == :none %}
        def {{ name.id }}(**attributes) : Nil
          open({{ tag }}, attributes, nil)
          leave({{ tag }})
        end
      {% else %}
        {% if [:flow, :phrasing, :details].includes?(spec[1]) %}
          def {{ name.id }}(text : String, **attributes) : Nil
            element({{ tag }}, attributes) { @backend.text(text) }
          end
        {% end %}

        def {{ name.id }}(**attributes, &) : Nil
          element({{ tag }}, attributes) { yield }
        end
      {% end %}
    {% end %}

    # Text inside the current element, escaped.
    def text(text : String) : Nil
      parent = @state.stack.last
      unless parent.holds_text?
        raise NestingError.new("<#{parent.name}> cannot hold text, only #{expected(parent)} (#{where})")
      end
      @backend.text(text)
    end

    # A whole HTML document: doctype, `<html lang>`, a head with the
    # character set, viewport, and *title*, and the block as the body. Only
    # at the top of a view, once; a layout usually calls it.
    #
    # The head loads the app's *stylesheets* and its *script* module
    # (`Punch.asset`), and Turbo unless *turbo* is false, through an import
    # map; all with `data-turbo-track="reload"`, so Turbo reloads the page
    # when a deploy changes them:
    #
    # ```
    # v.document(@title, stylesheets: {Punch.asset("app.css")}, script: Punch.asset("application.js")) do
    #   ...
    # end
    # ```
    #
    # With *morph*, Turbo morphs the page when it is refreshed (a live
    # page's `refresh`, a form that redirects to the same page) and keeps
    # the scroll position and the value of the field being typed in,
    # instead of replacing the body.
    def document(title : String, *, lang : String? = nil, stylesheets : Indexable(Asset::Stylesheet)? = nil,
                 script : Asset::Script? = nil, turbo : Bool = true, morph : Bool = false, &) : Nil
      if @state.mail?
        raise NestingError.new("a mail has no document: Punch writes it around the mail's view, with the subject as its title")
      end
      if @state.stream?
        raise NestingError.new("a Turbo Stream carries parts of a page, not a document: render the component inside the layout, not the layout")
      end
      if @state.document? || @state.stack.size > 1
        raise NestingError.new("document must be the outermost element of a view, and only one (#{where})")
      end
      @state.document = true
      @backend.start(Tag::Html)
      @backend.attribute("lang", lang || locale.code)
      @backend.started(Tag::Html)
      @backend.head(title, stylesheets.try(&.to_a) || [] of Asset::Stylesheet, document_scripts(script, turbo, morph), @state.alternate, morph && turbo)
      @backend.start(Tag::Body)
      @backend.started(Tag::Body)
      @state.stack << Tag::Body
      yield
      @state.stack.pop
      @state.live.try { |url| @backend.live_source(url) } if turbo
      @backend.finish(Tag::Body)
      @backend.finish(Tag::Html)
    end

    # Turbo, the script that keeps a typed value through a morph, the
    # app's script, and the script of upload fields when the app has kinds
    # of upload, in that order.
    private def document_scripts(script : Asset::Script?, turbo : Bool, morph : Bool) : Array(Asset::Script)
      scripts = [] of Asset::Script
      if turbo
        scripts << Assets.turbo
        scripts << Assets.morph if morph
      end
      scripts << script if script
      scripts << Assets.uploads if Upload.used?
      scripts
    end

    # Renders *component* here.
    def render(component : C) : Nil forall C
      check_renderable!
      component.view(self)
    end

    # Renders a layout, or any component that takes content, around the
    # block.
    def render(component : C, &) : Nil forall C
      check_renderable!
      component.view(self) { yield }
    end

    # Fails to compile when the component `C` writes raw HTML (it takes an
    # `HTMLView`) and this is a plain `View`, which renders pages agents
    # read and mail, so the message names the component.
    # :nodoc:
    private macro check_renderable!
      {% verbatim do %}
        {% for type in C.union_types %}
          {% raise "Punch::View#render takes a component (include Punch::Component), not #{type}" unless type < Punch::Component %}
          {% if @type == Punch::View %}
            {% for method in type.methods.select { |method| method.name == "view" } %}
              {% if method.args[0] && method.args[0].restriction.stringify.ends_with?("HTMLView") %}
                {% raise "#{type} takes a Punch::HTMLView, so it may write raw HTML, and cannot render where only semantic elements are allowed: on a page agents read (@[Punch::AgentReadable]) or in a mail. Write it with elements and take `v : Punch::View`; markup such as an icon belongs in a chrome block (`v.chrome { |c| c.raw(...) }`)." %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end

    # A form for a Command, bound to its input:
    #
    # ```
    # v.form(Customers::Update.action(customer_id: id), values: {name: customer.name, email: customer.email}) do |form|
    #   form.field :name
    #   form.field :email, hint: "Invoices are sent here"
    #   form.submit "Save"
    # end
    # ```
    #
    # *values* fill the fields, checked at compile time against the input
    # like `Page.href`. When the page shows a refused submission of this
    # form again, the form shows what was sent and the errors instead,
    # with a list of every error at its top. Field names are checked by
    # the compiler (`form.field :emial` does not compile).
    #
    # A form for a Command the viewer may not run, by its policy, is left
    # out with everything in its block.
    #
    # A page must hold the form (`SendPage` for `Send`, or
    # `@[Punch::Forms(Send)]`), so a refusal has a page to show it on;
    # without one this does not compile.
    #
    # A form for a `PATCH`, `PUT`, or `DELETE` Command posts with
    # `?_method=` on its action, which works with and without JavaScript.
    # With *turbo_method*, it carries the method itself
    # (`method="patch"`), as Turbo sends it; a browser without Turbo then
    # sends a `GET` instead, so use it only where Turbo is certain.
    #
    # With *idempotent*, the form carries a generated idempotency key in a
    # hidden field, so a double submit runs the Command once and the
    # second gets the first answer. Forms for Commands that require a key
    # always carry one.
    def form(action : Action(C), *, values : NamedTuple? = nil, turbo_method : Bool = false, idempotent : Bool = false,
             **attributes : **A, &) : Nil forall C, A
      {% begin %}
        {% pages = Punch::Page.all_subclasses.reject(&.abstract?) %}
        {% holder = pages.find { |candidate| candidate.has_constant?("PunchForms") && parse_type("::#{candidate}::PunchForms").resolve.type_vars.includes?(C) } ||
                    pages.find { |candidate| candidate.name.stringify == "#{C}Page" } %}
        {% unless holder %}
          {% raise "Punch::View#form: no page holds the form of #{C}. A refused submission is shown again on that page, with the errors: name it #{C}Page, or list #{C} in @[Punch::Forms(...)] on the page that shows the form." %}
        {% end %}
        {% for key in %w[id method action] %}
          {% raise "Punch::View#form: Punch sets `#{key.id}`; leave it out" if A.keys.map(&.stringify).includes?(key) %}
        {% end %}
      {% end %}
      if @state.mail?
        raise NestingError.new("a mail cannot hold a form: link to the page that has it (#{where})")
      end
      return unless permitted?(action.permit)

      submission = @state.submission.try { |sent| sent if sent.for?(C.name, action.path) }
      @state.submission_shown = true if submission
      current = submission ? submission.form : Input::Form.encode(C::Input, values)
      errors = submission ? submission.errors : [] of Rejection::FieldError
      id = Form.id(action.path, action.method)
      enter(Tag::Form)
      @backend.start(Tag::Form)
      @backend.attribute("id", id)
      native = turbo_method && action.method != "POST"
      @backend.attribute("method", native ? action.method.downcase : "post")
      @backend.attribute("action", Href.new(native ? action.path : action.url, nil))
      write_attributes(attributes)
      if @backend.describes_forms?
        problems = errors.map { |error| FormTarget::Problem.new(Form.name(error.path), Form.message(locale, error), error.code) }
        @backend.form_target(FormTarget.for(C, action.method, action.path, problems))
      end
      @backend.started(Tag::Form)
      builder = Form(C::Input).new(self, id, nil, current, errors)
      builder.summary
      mode = Routing.idempotency(C)
      if idempotent || mode == :required
        raise ArgumentError.new("#{C} takes no idempotency key, so its form cannot carry one (lib/punch/docs/operations.md)") if mode == :none
        # A form shown again after a refusal keeps its key: the refusal
        # changed nothing and was not stored.
        builder.idempotency_key(current[IdempotencyKeys::FIELD]? || Random::Secure.urlsafe_base64(18))
      end
      yield builder
      leave(Tag::Form)
    end

    # A `GET` form to a page: the filter, order, and direction of a list. It
    # shows *values*, the page's input as parsed, so the form keeps what the
    # list was filtered by, and sends what it holds as the page's query
    # string; fields are named as `Page.href` writes them
    # (`filter[status]`). Fields the form does not show are not sent: a
    # cursor (`after`) is dropped, so a new filter starts at the first page.
    # The form goes to the page at the path parameters of *values*.
    #
    # ```
    # v.filter_form(IndexPage, input) do |form|
    #   form.fields(:filter, Queries::Page::Filter) do |filter|
    #     filter.field :status
    #     filter.field :customer_id, as: :select, options: customers
    #   end
    #   form.field :limit, as: :hidden
    #   form.submit t.filter
    # end
    # ```
    #
    # Shown only to an actor the page's policy admits. Nothing is checked
    # in the form: a filter that does not parse answers 422 from the page.
    def filter_form(page : P.class, values : I, **attributes : **A, & : Form(I) ->) : Nil forall P, I, A
      {% begin %}
        {% raise "Punch::View#filter_form: #{P} is not a page" unless P < Punch::Page %}
        {% raise "Punch::View#filter_form: give #{P}'s input (#{P}::Input), not #{I}" unless I == parse_type("::#{P}::Input").resolve %}
        {% for key in %w[id method action] %}
          {% raise "Punch::View#filter_form: Punch sets `#{key.id}`; leave it out" if A.keys.map(&.stringify).includes?(key) %}
        {% end %}
      {% end %}
      if @state.mail?
        raise NestingError.new("a mail cannot hold a form: link to the page that has it (#{where})")
      end
      target = P.path_of(values)
      return unless permitted?(target.permit)

      current = URI::Params.new
      values.__punch_encode(current, nil)
      id = Form.id(target.url, "get")
      enter(Tag::Form)
      @backend.start(Tag::Form)
      @backend.attribute("id", id)
      @backend.attribute("method", "get")
      @backend.attribute("action", target)
      write_attributes(attributes)
      @backend.form_target(FormTarget.for(P, "GET", target.url)) if @backend.describes_forms?
      @backend.started(Tag::Form)
      yield Form(I).new(self, id, nil, current, [] of Rejection::FieldError)
      leave(Tag::Form)
    end

    # A Turbo Frame (`<turbo-frame>`), a part of the page that links and
    # forms inside it replace on their own. Its DOM ID comes from a typed
    # ID (`Punch.dom_id`): `v.frame(invoice.id) { ... }` is
    # `<turbo-frame id="invoices_42">`. *src* loads it lazily from a page.
    def frame(id : TypedID, prefix : String? = nil, *, src : Href? = nil, **attributes, &) : Nil
      enter(Tag::TurboFrame)
      @backend.start(Tag::TurboFrame)
      @backend.attribute("id", Punch.dom_id(id, prefix))
      @backend.attribute("src", src) if src
      write_attributes(attributes)
      @backend.started(Tag::TurboFrame)
      yield
      leave(Tag::TurboFrame)
    end

    # Navigation, scripts, and decoration around a page's content: written
    # in HTML, left out of the markdown that agents read and out of mail.
    # The block gets an `HTMLView`, so `raw` is allowed inside:
    # `v.chrome { |chrome| chrome.nav { ... } }`.
    def chrome(& : HTMLView ->) : Nil
      yield html_view if @backend.chrome? && !@state.mail?
    end

    protected def html_view : HTMLView
      HTMLView.new(@backend, @state)
    end

    # Inlined at every call site, so it only opens, yields, and closes.
    private def element(tag : Tag, attributes : NamedTuple, href : Href? = nil, &) : Nil
      open(tag, attributes, href)
      yield
      leave(tag)
    end

    protected def open(tag : Tag, attributes : NamedTuple, href : Href?) : Nil
      enter(tag)
      @backend.start(tag)
      @backend.attribute("href", href) if href
      write_attributes(attributes)
      @backend.started(tag)
    end

    # Opens an element Punch writes (forms, controls): the block writes
    # Punch's attributes, then *attributes* from the component follow.
    # Those may not repeat what Punch writes.
    # A fact for the next control's description (`Backend#describe`).
    protected def describe_next(name : String, value : String) : Nil
      (@described ||= [] of {String, String}) << {name, value} if @backend.describes_forms?
    end

    @described : Array({String, String})?

    protected def open_with(tag : Tag, attributes : T, &) : Nil forall T
      {% for key in T.keys %}
        {% if %w[name id type value for checked selected multiple form method action].includes?(key.stringify) %}
          {% raise "Punch::View: Punch writes `#{key.id}` on form controls; leave it out" %}
        {% end %}
      {% end %}
      enter(tag)
      @backend.start(tag)
      yield
      if described = @described
        described.each { |(name, value)| @backend.describe(name, value) }
        @described = nil
      end
      write_attributes(attributes)
      @backend.started(tag)
    end

    protected def enter(tag : Tag) : Nil
      parent = @state.stack.last
      unless parent.allows?(tag)
        raise NestingError.new(misplaced(tag, parent))
      end
      if tag.form?
        raise NestingError.new("<form> cannot hold another <form> (#{where})") if @state.forms > 0
        @state.forms += 1
      elsif tag.control? && @state.forms == 0
        raise NestingError.new("<#{tag.name}> belongs inside a form (#{where})")
      end
      if tag.a?
        raise NestingError.new("<a> cannot hold another <a> (#{where})") if @state.links > 0
        @state.links += 1
      end
      @state.stack << tag
    end

    protected def leave(tag : Tag) : Nil
      @state.stack.pop
      @state.links -= 1 if tag.a?
      @state.forms -= 1 if tag.form?
      @backend.finish(tag)
    end

    private def misplaced(tag : Tag, parent : Tag) : String
      {% begin %}
      parents = case tag
                {% for name, parents in PARTS %}
                  when Tag::{{ name.id.camelcase }} then {{ parents.map { |parent| "<#{parent.id}>" }.join(" or ") }}
                {% end %}
                end
      if parents
        "<#{tag.name}> belongs directly inside #{parents}, not <#{parent.name}> (#{where})"
      else
        "<#{parent.name}> can hold only #{expected(parent)}, not <#{tag.name}> (#{where})"
      end
      {% end %}
    end

    private def expected(parent : Tag) : String
      case parent.content
      when :phrasing then "text and phrasing elements such as <strong> or <a>"
      when :list     then "<li>"
      when :terms    then "<dt> and <dd>"
      when :table    then "<caption>, <thead>, <tbody>, and <tfoot>"
      when :rows     then "<tr>"
      when :cells    then "<th> and <td>"
      when :options  then "<option>"
      when :none     then "nothing"
      else                "blocks and text"
      end
    end

    private def where : String
      path = @state.stack.reject(&.fragment?).map(&.name)
      path.empty? ? "at the top" : "in #{path.join(" > ")}"
    end

    # Writes each attribute, checked at compile time.
    protected def write_attributes(attributes : T) : Nil forall T
      {% for key in T.keys %}
        {% name = key.stringify %}
        {% type = T[key] %}
        {% unless name =~ /\A[a-z][a-z0-9_]*\z/ %}
          {% raise "Punch::View: attribute `#{name.id}` is not a valid name; use lowercase letters, digits, and underscores (written as hyphens)" %}
        {% end %}
        {% if name.starts_with?("on") %}
          {% raise "Punch::View: no `#{name.id}`. Inline event handlers are blocked by the Content-Security-Policy; attach behaviour with a Stimulus controller (data: {controller: ...})" %}
        {% end %}
        {% if name == "style" %}
          {% raise "Punch::View: no `style`. Inline styles are blocked by the Content-Security-Policy; use a class" %}
        {% end %}
        {% if name == "href" %}
          {% raise "Punch::View: only <a> takes `href`" %}
        {% end %}
        {% if URL_ATTRIBUTES.includes?(name) %}
          {% unless type.union_types.all? { |member| member == ::Nil || member <= ::Punch::Href } %}
            {% raise "Punch::View: `#{name.id}` takes a Punch::Href (SomePage.href(...) or Punch::Href.external(...)), not #{type}" %}
          {% end %}
          attribute({{ name }}, attributes[{{ key.symbolize }}])
        {% elsif name == "data" || name == "aria" %}
          {% raise "Punch::View: `#{name.id}` takes named values, such as #{name.id}: {turbo_frame: \"lines\"}, not #{type}" unless type < NamedTuple %}
          {% for sub in type.keys %}
            {% unless sub.stringify =~ /\A[a-z][a-z0-9_]*\z/ %}
              {% raise "Punch::View: `#{name.id}-#{sub.id}` is not a valid attribute name" %}
            {% end %}
            token_attribute({{ name + "-" + sub.stringify.gsub(/_/, "-") }}, attributes[{{ key.symbolize }}][{{ sub.symbolize }}])
          {% end %}
        {% else %}
          {% for member in type.union_types %}
            {% unless member == ::Nil || member == ::String || member == ::Bool || member < ::Number || member == ::Time ||
                        (name == "class" && (member < ::Array || member < ::Tuple)) %}
              {% raise "Punch::View: `#{name.id}` takes a String, a number, a Bool, or a Time, not #{member}#{name == "class" ? ", or a list of class names".id : "".id}" %}
            {% end %}
          {% end %}
          attribute({{ name.gsub(/_/, "-") }}, attributes[{{ key.symbolize }}])
        {% end %}
      {% end %}
    end

    private def attribute(name : String, value : String) : Nil
      @backend.attribute(name, value)
    end

    private def attribute(name : String, value : Href) : Nil
      @backend.attribute(name, value)
    end

    private def attribute(name : String, value : Bool) : Nil
      @backend.attribute(name) if value
    end

    private def attribute(name : String, value : Nil) : Nil
    end

    private def attribute(name : String, value : Number) : Nil
      @backend.attribute(name, value.to_s)
    end

    private def attribute(name : String, value : Time) : Nil
      @backend.attribute(name, value.to_rfc3339)
    end

    # Class names: `class: ["invoice", ("overdue" if overdue)]`.
    private def attribute(name : String, value : Array | Tuple) : Nil
      names = value.compact_map { |item| item.as(String?).presence }
      @backend.attribute(name, names.join(' ')) unless names.empty?
    end

    # `data-` and `aria-` values: booleans are written as "true" and
    # "false", as Turbo, Stimulus, and ARIA read them.
    private def token_attribute(name : String, value : String | Number | Bool) : Nil
      @backend.attribute(name, value.to_s)
    end

    private def token_attribute(name : String, value : Href) : Nil
      @backend.attribute(name, value)
    end

    private def token_attribute(name : String, value : Nil) : Nil
    end

    private def permitted?(permit : Proc(Policy::Authorizer, Bool)?) : Bool
      return true unless permit

      authorizer = @state.authorizer || return true
      permit.call(authorizer)
    end
  end

  # A view that may also write markup as it is, with `raw`. Pages that
  # only people see render through it; pages agents read render through a
  # plain `View` (`View.markdown`), and `chrome` blocks get one everywhere.
  class HTMLView < View
    # Writes *html* as it is, wherever text could go.
    def raw(html : SafeHTML) : Nil
      parent = state.stack.last
      unless parent.holds_text?
        raise NestingError.new("<#{parent.name}> cannot hold raw HTML, only #{expected(parent)} (#{where})")
      end
      backend.raw(html)
    end

    protected def html_view : HTMLView
      self
    end

    # Renders *component* as a whole HTML page or fragment; with
    # *submission*, the form it refused shows the values and errors; with
    # *authorizer*, forms and links ask their policies; in *locale*, the
    # default locale without one. *alternate* names the page's markdown
    # in the head; *live* is the stream a live page opens.
    def self.render(component : Component, submission : Submission? = nil, authorizer : Policy::Authorizer? = nil,
                    locale : Locale? = nil, *, alternate : String? = nil, live : String? = nil) : SafeHTML
      html = String.build do |io|
        view = new(HTMLBackend.new(io), State.new(submission, authorizer, locale, alternate: alternate, live: live))
        view.render(component)
      end
      # ameba:disable Punch/TrustedHTML
      SafeHTML.trusted(html)
    end
  end
end
