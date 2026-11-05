module Punch
  # Turbo Stream actions: changes to parts of a page that is already shown,
  # each carrying a component rendered as HTML. The same component renders
  # as a whole page, inside a frame, or here, without a second template.
  #
  # ```
  # Punch::TurboStream.build do |stream|
  #   stream.prepend "invoices", InvoiceRow.new(row)
  #   stream.replace invoice.id, InvoiceSummary.new(invoice) # target invoices_42
  #   stream.remove line.id
  # end
  # ```
  #
  # A target is a DOM ID: a typed ID becomes one by `Punch.dom_id`
  # (`invoices_42`, as `View#frame` writes it); give
  # `Punch.dom_id(id, "lines")` for a prefixed one, or a string for an
  # element the page names itself (`v.tbody(id: "invoices")`).
  #
  # A holding page answers a Command's form with one (`Page.stream`);
  # live updates send them to every open page. Components render through an
  # `HTMLView`, so raw HTML is allowed; `v.document` is not, since a stream
  # carries parts of a page.
  class TurboStream
    # What Turbo does with an action's content.
    enum Action
      Append
      Prepend
      Replace
      Update
      Before
      After
      Remove
      Refresh
    end

    # :nodoc:
    record Change, action : Action, target : String?, content : Proc(HTMLView, Nil)?, morph : Bool

    getter changes = [] of Change

    def self.build(& : self ->) : self
      stream = new
      yield stream
      stream
    end

    # Adds *component* as the last child of *target*.
    def append(target : TypedID | String, component : C) : self forall C
      add(:append, target, component)
    end

    # Adds *component* as the first child of *target*.
    def prepend(target : TypedID | String, component : C) : self forall C
      add(:prepend, target, component)
    end

    # Puts *component* in place of *target*, the element itself. With
    # *morph*, Turbo changes only what differs, keeping focus and state.
    def replace(target : TypedID | String, component : C, *, morph : Bool = false) : self forall C
      add(:replace, target, component, morph)
    end

    # Puts *component* in place of what *target* holds, keeping the
    # element.
    def update(target : TypedID | String, component : C, *, morph : Bool = false) : self forall C
      add(:update, target, component, morph)
    end

    # Adds *component* right before *target*, as its sibling.
    def before(target : TypedID | String, component : C) : self forall C
      add(:before, target, component)
    end

    # Adds *component* right after *target*, as its sibling.
    def after(target : TypedID | String, component : C) : self forall C
      add(:after, target, component)
    end

    # Removes *target*.
    def remove(target : TypedID | String) : self
      @changes << Change.new(:remove, TurboStream.target(target), nil, false)
      self
    end

    # Makes Turbo fetch the current page again and show what changed
    # (Turbo 8's page refresh): for a change too wide for single actions.
    def refresh : self
      @changes << Change.new(:refresh, nil, nil, false)
      self
    end

    def empty? : Bool
      @changes.empty?
    end

    # The actions as `text/vnd.turbo-stream.html`. With *authorizer*, forms
    # and links ask their policies, as on a page; in *locale*, the default
    # locale without one.
    def render(authorizer : Policy::Authorizer? = nil, locale : Locale? = nil) : SafeHTML
      html = String.build do |io|
        view = HTMLView.new(View::HTMLBackend.new(io), View::State.new(nil, authorizer, locale, stream: true))
        @changes.each do |change|
          io << "<turbo-stream action=\"" << change.action.to_s.downcase << '"'
          if target = change.target
            io << " target=\""
            ::HTML.escape(target, io)
            io << '"'
          end
          io << " method=\"morph\"" if change.morph
          io << '>'
          if content = change.content
            io << "<template>"
            content.call(view)
            io << "</template>"
          end
          io << "</turbo-stream>\n"
        end
      end
      # ameba:disable Punch/TrustedHTML
      SafeHTML.trusted(html)
    end

    # A DOM ID: an HTML ID cannot be empty or hold whitespace.
    # :nodoc:
    def self.target(target : TypedID) : String
      Punch.dom_id(target)
    end

    # :ditto:
    def self.target(target : String) : String
      if target.empty? || target.each_char.any?(&.whitespace?)
        raise ArgumentError.new("A Turbo Stream target is a DOM ID, without whitespace: #{target.inspect}")
      end
      target
    end

    # Built here, not in the caller's block, so the proc captures only
    # this method's argument.
    private def add(action : Action, target : TypedID | String, component : C, morph : Bool = false) : self forall C
      {% raise "Punch::TurboStream: #{C} is not a component (include Punch::Component)" unless C < Punch::Component %}
      @changes << Change.new(action, TurboStream.target(target), ->(view : HTMLView) { view.render(component) }, morph)
      self
    end
  end
end
