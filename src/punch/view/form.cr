module Punch
  # The DOM ID of a record, for Turbo Frames and anchors: the namespace of
  # its typed ID and the number, `invoices_42` for a `Billing::Invoices::ID`,
  # or `lines_invoices_42` with *prefix* `lines`.
  def self.dom_id(id : TypedID, prefix : String? = nil) : String
    parts = id.class.name.split("::")
    base = id.class.public_prefix ? id.to_s : "#{(parts[-2]? || parts[-1]).underscore}_#{id.value}"
    prefix ? "#{prefix}_#{base}" : base
  end

  class View
    # Writes the fields of one input inside `View#form`: labels, controls,
    # hints, and errors, each named as the input parser reads it. Fields are
    # named by symbols the compiler checks against the input
    # (`form.field :email`).
    #
    # ```
    # v.form(Invoices::Create.action) do |form|
    #   form.field :customer_id, as: :select, options: customers.map { |c| {c.id, c.display_name} }
    #   form.field :currency
    #   v.fieldset do
    #     v.legend "Lines"
    #     form.each(:lines, Invoices::LineInput, blank: 1) do |line|
    #       line.field :description
    #       line.field :quantity
    #     end
    #   end
    #   form.submit "Create invoice"
    # end
    # ```
    #
    # The control follows the field's type: a checkbox for a `Bool` with a
    # default, a select for an enum or another `Bool`, a number for
    # integers, IDs, and amounts, text otherwise, with the length and range
    # of a domain primitive's schema. `as:` chooses another
    # (`:textarea`, `:password`, `:hidden`, `:select`). A required field is
    # marked `required`, so browsers check it before sending; the server
    # checks it again.
    class Form(I)
      # What a field is written as.
      enum Control
        Text
        Textarea
        Password
        Hidden
        Checkbox
        Select
      end

      # The form's DOM ID, from where it is sent: `billing-invoices-42-send-post`.
      def self.id(path : String, method : String) : String
        slug = path.gsub(/[^A-Za-z0-9]+/, "-").strip('-')
        slug.empty? ? method.downcase : "#{slug}-#{method.downcase}"
      end

      # The name of the field at *path*: `lines[0][description]` for
      # `["lines", 0, "description"]`; empty for the form as a whole.
      def self.name(path : Rejection::Path) : String
        String.build do |io|
          path.each_with_index do |part, index|
            index == 0 ? (io << part) : (io << '[' << part << ']')
          end
        end
      end

      # A label people read, from a field's name: `company_name` is
      # "Company name", `customer_id` "Customer". A view uses its locale's
      # `fields.<name>` first (`View#locale`, `Locale#field`).
      def self.label(key : String) : String
        I18n.humanize(key)
      end

      # :nodoc:
      def initialize(@view : View, @id : String, @prefix : String?, @values : URI::Params, @errors : Array(Rejection::FieldError))
      end

      # A field with its label, control, hint, and errors, in a
      # `<div class="field">` (`field-invalid` when it has errors).
      def field(name : I::PunchField, *, label : String? = nil, hint : String? = nil, as control : Control? = nil,
                options : Enumerable? = nil, **attributes) : Nil
        key = key(name)
        kind = control || default_control(name)
        if kind.hidden?
          return control(name, **attributes, as: kind)
        end

        invalid = !errors_at(key).empty?
        @view.div(class: ["field", ("field-checkbox" if kind.checkbox?), ("field-invalid" if invalid)]) do
          if kind.checkbox?
            control(name, **attributes, as: kind, hint: !hint.nil?, options: options)
            label(name, label)
          else
            label(name, label)
            control(name, **attributes, as: kind, hint: !hint.nil?, options: options)
          end
          if hint
            @view.p hint, class: "field-hint", id: "#{field_id(key)}-hint"
          end
          errors(name)
        end
      end

      # The label of a field alone.
      def label(name : I::PunchField, text : String? = nil, **attributes) : Nil
        key = key(name)
        @view.open_with(Tag::Label, attributes) { @view.backend.attribute("for", field_id(key)) }
        @view.backend.text(text || @view.locale.field(name.key.to_s))
        @view.leave(Tag::Label)
      end

      # The control of a field alone, for layouts `field` does not fit, such
      # as a table with one row per line. *hint*: a hint follows, which
      # the control points to.
      def control(name : I::PunchField, *, as control : Control? = nil, hint : Bool = false,
                  options : Enumerable? = nil, **attributes) : Nil
        {% begin %}
          case name
          {% for ivar in I.instance_vars %}
            in .{{ ivar.name }}?
              {% if ivar.annotation(Punch::PathParam) %}
                raise ArgumentError.new({{ "#{I}##{ivar.name} is a path parameter: the action carries it (Command.action), not a field" }})
              {% else %}
                write({{ ivar.type.union_types.reject(&.==(::Nil)).first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, key(name),
                  {{ !ivar.type.nilable? && !ivar.has_default_value? }}, {{ ivar.type.nilable? }},
                  control, hint, options, attributes)
              {% end %}
          {% end %}
          end
        {% end %}
      end

      # The errors of a field: one `<p class="field-error">` each, the
      # code's message in the view's locale, or the code where there is
      # none; the code is in `data-code`.
      def errors(name : I::PunchField) : Nil
        key = key(name)
        found = errors_at(key)
        return if found.empty?

        @view.div(class: "field-errors", id: "#{field_id(key)}-error") do
          found.each { |error| @view.p message(error), class: "field-error", data: {code: error.code} }
        end
      end

      # One builder per row of an array of inputs (`lines[0][...]`): the
      # rows the values hold, then *blank* empty ones to fill in. Empty rows
      # are not sent as rows (`Input.from_form`). *type* is the rows' input,
      # which the field must hold.
      def each(name : I::PunchField, type : T.class, *, blank : Int32 = 0, & : Form(T), Int32 ->) : Nil forall T
        check_nested(name, Array(T))
        key = key(name)
        (rows(key) + blank).times do |index|
          yield Form(T).new(@view, @id, "#{key}[#{index}]", @values, @errors), index
        end
      end

      # A builder for a nested input (`address[street]`).
      def fields(name : I::PunchField, type : T.class, & : Form(T) ->) : Nil forall T
        check_nested(name, T)
        yield Form(T).new(@view, @id, key(name), @values, @errors)
      end

      # The button that sends the form.
      def submit(text : String, **attributes) : Nil
        @view.open_with(Tag::Button, attributes) { @view.backend.attribute("type", "submit") }
        @view.backend.text(text)
        @view.leave(Tag::Button)
      end

      # :nodoc:
      # Every error of the form, linked to its field, at the top of the
      # form: people who cannot see the page all at once find them there.
      # The hidden field with the form's idempotency key. :nodoc:
      def idempotency_key(value : String) : Nil
        input(IdempotencyKeys::FIELD, "hidden", NamedTuple.new, false, value: value)
      end

      def summary : Nil
        return if @errors.empty?

        locale = @view.locale
        @view.div(class: "form-errors", role: "alert") do
          locale.translate?("punch.page.errors").try { |heading| @view.p heading }
          @view.ul do
            @errors.each do |error|
              key = Form.name(error.path)
              @view.li(data: {code: error.code}) do
                unless key.empty?
                  last = error.path.reverse.find(&.is_a?(String)).as?(String) || key
                  @view.a locale.field(last), href: Href.fragment(field_id(key))
                  @view.text ": "
                end
                @view.text message(error)
              end
            end
          end
        end
      end

      # The error's message; one for the whole form (a failure result
      # such as `invalid_credentials`) may be a problem's.
      private def message(error : Rejection::FieldError) : String
        Form.message(@view.locale, error)
      end

      # :nodoc:
      def self.message(locale : Locale, error : Rejection::FieldError) : String
        found = locale.error?(error.code, error.params)
        found ||= locale.problem?(error.code, error.params) if error.path.empty?
        found || error.code
      end

      private def key(name : I::PunchField) : String
        Input::Form.key(@prefix, name.key)
      end

      private def field_id(key : String) : String
        "#{@id}-#{key.gsub(/[\[\]]+/, "-").strip('-')}"
      end

      private def errors_at(key : String) : Array(Rejection::FieldError)
        @errors.select { |error| Form.name(error.path) == key }
      end

      # How many rows of *key* the values hold, up to the last that has one.
      private def rows(key : String) : Int32
        start = "#{key}["
        count = 0
        @values.each do |name, value|
          next if value.empty? || !name.starts_with?(start)
          close = name.index(']', start.size) || next
          index = name[start.size...close].to_i? || next
          count = index + 1 if index + 1 > count
        end
        count
      end

      private def check_nested(name : I::PunchField, type : T.class) : Nil forall T
        {% begin %}
          case name
          {% for ivar in I.instance_vars %}
            in .{{ ivar.name }}?
              {% field = ivar.type.union_types.reject(&.==(::Nil)).first %}
              {% unless field == T %}
                raise ArgumentError.new({{ "#{I}##{ivar.name} is #{field}, not #{T}" }})
              {% end %}
          {% end %}
          end
        {% end %}
      end

      private def default_control(name : I::PunchField) : Control
        {% begin %}
          case name
          {% for ivar in I.instance_vars %}
            {% type = ivar.type.union_types.reject(&.==(::Nil)).first %}
            in .{{ ivar.name }}?
              {% if type == ::Bool %}
                {{ ivar.has_default_value? ? "Control::Checkbox".id : "Control::Select".id }}
              {% elsif type < ::Enum || (type < ::Array && type.type_vars.first < ::Enum) %}
                Control::Select
              {% elsif type == ::Punch::Auth::Password || type == ::Punch::Auth::NewPassword %}
                # Passwords are never written back into a form.
                Control::Password
              {% else %}
                Control::Text
              {% end %}
          {% end %}
          end
        {% end %}
      end

      # Writes the control for a field of *type*. *required*: neither
      # nilable nor defaulted; *nilable*: may be left empty on purpose.
      private def write(type : T.class, key : String, required : Bool, nilable : Bool, control : Control?,
                        hint : Bool, options : Enumerable?, attributes : NamedTuple) : Nil forall T
        {% if T < ::Punch::Input || (T < ::Array && T.type_vars.first < ::Punch::Input) %}
          raise ArgumentError.new("#{key} holds #{T}: write its fields with `each` or `fields`")
        {% elsif T < ::Array %}
          {% item = T.type_vars.first %}
          {% if item < ::Enum %}
            choices = options ? choices(options) : {{ item.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.values.map { |member| {Routing.segment(member), Form.label(member.to_s.underscore)} }
            select_control(key, choices, multiple: true, required: required, blank: false, hint: hint, attributes: attributes)
          {% else %}
            raise ArgumentError.new("#{key} holds #{T}: write one control per item")
          {% end %}
        {% elsif T == ::Punch::Upload::Ticket %}
          upload(key, required, hint, attributes)
        {% elsif T == ::Bool %}
          kind = control || (nilable || required ? Control::Select : Control::Checkbox)
          if kind.checkbox?
            input(key, "checkbox", attributes, hint, value: "true", checked: current(key) == "true")
          else
            select_control(key, options ? choices(options) : [{"true", "Yes"}, {"false", "No"}], multiple: false, required: required, blank: !required, hint: hint, attributes: attributes)
          end
        {% elsif T < ::Enum %}
          if (control || Control::Select).select?
            choices = options ? choices(options) : T.values.map { |member| {Routing.segment(member), Form.label(member.to_s.underscore)} }
            select_control(key, choices, multiple: false, required: required, blank: !required, hint: hint, attributes: attributes)
          else
            text(key, control, required, hint, attributes, "text")
          end
        {% else %}
          {% if T == ::Time %}
            @view.describe_next("format", "date-time")
          {% end %}
          {% primitive = T.ancestors.find { |ancestor| ancestor.name(generic_args: false) == "Punch::Primitive" } %}
          {% base = primitive ? primitive.type_vars.first : T %}
          {% schema = T.class.has_method?("json_schema") %}
          if (control || Control::Text).select?
            select_control(key, options ? choices(options) : [] of {String, String}, multiple: false, required: required, blank: !required, hint: hint, attributes: attributes)
          else
            {% if base == ::Int32 || base == ::Int64 || base == ::Float64 %}
              {% if schema %}
                schema = T.json_schema
                minimum, maximum = schema[:minimum]?, schema[:maximum]?
              {% else %}
                minimum = maximum = nil
              {% end %}
              number(key, control, required, hint, attributes, minimum, maximum, {{ base == ::Float64 ? "any" : "1" }})
            {% else %}
              {% if schema %}
                schema = T.json_schema
                schema[:format]?.try { |format| @view.describe_next("format", format.to_s) }
                text(key, control, required, hint, attributes, schema[:format]? == "email" ? "email" : "text",
                  schema[:minLength]?, schema[:maxLength]?, schema[:format]?.try(&.ends_with?("email")),
                  {% if T == ::Punch::Auth::NewPassword %} "new-password" {% elsif T == ::Punch::Auth::Password %} "current-password" {% elsif T == ::Punch::Auth::OneTimeCode %} "one-time-code" {% else %} nil {% end %})
              {% else %}
                text(key, control, required, hint, attributes, "text")
              {% end %}
            {% end %}
          end
        {% end %}
      end

      private def text(key : String, control : Control?, required : Bool, hint : Bool, attributes : NamedTuple,
                       type : String, min_length = nil, max_length = nil, email : Bool? = nil, autocomplete : String? = nil) : Nil
        case control
        when Control::Textarea
          @view.open_with(Tag::Textarea, attributes) do
            common(key, required, hint)
            length(min_length, max_length)
          end
          # A newline right after <textarea> is dropped by parsers, so one
          # is written whenever the value starts with one.
          @view.backend.text("\n") if current(key).try(&.starts_with?('\n'))
          @view.backend.text(current(key) || "")
          @view.leave(Tag::Textarea)
        when Control::Password
          input(key, "password", attributes, hint, required: required, value: nil, min_length: min_length, max_length: max_length,
            autocomplete: autocomplete)
        when Control::Hidden
          input(key, "hidden", attributes, false, value: current(key))
        else
          # A one-time code is not written back either: it was used or wrong.
          one_time = autocomplete == "one-time-code"
          input(key, type, attributes, hint, required: required, value: one_time ? nil : current(key), min_length: min_length,
            max_length: max_length, email: email, autocomplete: autocomplete)
        end
      end

      private def number(key : String, control : Control?, required : Bool, hint : Bool, attributes : NamedTuple,
                         minimum, maximum, step : String) : Nil
        case control
        when Control::Hidden   then input(key, "hidden", attributes, false, value: current(key))
        when Control::Password then input(key, "password", attributes, hint, required: required)
        when Control::Textarea then text(key, control, required, hint, attributes, "text")
        else
          input(key, "number", attributes, hint, required: required, value: current(key), minimum: minimum, maximum: maximum, step: step)
        end
      end

      private def input(key : String, type : String, attributes : NamedTuple, hint : Bool, *, required : Bool = false,
                        value : String? = nil, checked : Bool = false, min_length = nil, max_length = nil,
                        minimum = nil, maximum = nil, step : String? = nil, email : Bool? = nil, autocomplete : String? = nil) : Nil
        backend = @view.backend
        @view.open_with(Tag::Input, attributes) do
          backend.attribute("type", type)
          if type == "hidden"
            backend.attribute("name", key)
          else
            common(key, required, hint)
          end
          backend.attribute("value", value) if value
          backend.attribute("checked") if checked
          length(min_length, max_length)
          backend.attribute("min", minimum.to_s) if minimum
          backend.attribute("max", maximum.to_s) if maximum
          backend.attribute("step", step) if step
          if email
            backend.attribute("inputmode", "email")
            backend.attribute("autocomplete", "email") unless attributes.has_key?(:autocomplete)
          end
          # Lets password managers tell a sign-in from a new password.
          backend.attribute("autocomplete", autocomplete) if autocomplete && !attributes.has_key?(:autocomplete)
        end
        @view.leave(Tag::Input)
      end

      private def select_control(key : String, choices : Array({String, String}), *, multiple : Bool, required : Bool,
                                 blank : Bool, hint : Bool, attributes : NamedTuple) : Nil
        selected = @values.fetch_all(key)
        @view.open_with(Tag::Select, attributes) do
          common(key, required, hint)
          @view.backend.attribute("multiple") if multiple
        end
        option("", "", selected.empty? || selected == [""]) if blank
        choices.each { |value, text| option(value, text, selected.includes?(value)) }
        @view.leave(Tag::Select)
      end

      private def option(value : String, text : String, selected : Bool) : Nil
        @view.open_with(Tag::Option, NamedTuple.new) do
          @view.backend.attribute("value", value)
          @view.backend.attribute("selected") if selected
        end
        @view.backend.text(text)
        @view.leave(Tag::Option)
      end

      # `options:` as value and label pairs, values written as the parser
      # reads them.
      private def choices(options : Enumerable) : Array({String, String})
        options.map { |(value, text)| {Routing.segment(value), text.to_s} }.to_a
      end

      # What every visible control has: name, ID, `required`, and when it
      # has errors, `aria-invalid` and a pointer to them.
      private def common(key : String, required : Bool, hint : Bool) : Nil
        backend = @view.backend
        id = field_id(key)
        backend.attribute("name", key)
        backend.attribute("id", id)
        backend.attribute("required") if required
        described = [] of String
        described << "#{id}-hint" if hint
        unless errors_at(key).empty?
          backend.attribute("aria-invalid", "true")
          described << "#{id}-error"
        end
        backend.attribute("aria-describedby", described.join(' ')) unless described.empty?
      end

      # An upload (`Punch::Upload::Ticket`, docs/uploads.md): a file
      # control without a name, so the file never goes to the app, and a
      # hidden field for the ticket. Punch's upload script sends the file
      # to the storage with the grant from `data-punch-upload` (the path
      # of the app's granting Command) and puts the ticket into the hidden
      # field. A ticket sent before, on a form shown again, stays.
      private def upload(key : String, required : Bool, hint : Bool, attributes : NamedTuple) : Nil
        backend = @view.backend
        id = field_id(key)
        current = current(key)
        @view.open_with(Tag::Input, attributes) do
          backend.attribute("type", "file")
          backend.attribute("id", id)
          backend.attribute("required") if required && current.nil?
          backend.attribute("data-punch-upload-ticket", "#{id}-ticket")
          locale = @view.locale
          locale.translate?("punch.page.uploading").try { |text| backend.attribute("data-punch-upload-busy", text) }
          locale.translate?("punch.page.upload_failed").try { |text| backend.attribute("data-punch-upload-failed", text) }
          described = [] of String
          described << "#{id}-hint" if hint
          unless errors_at(key).empty?
            backend.attribute("aria-invalid", "true")
            described << "#{id}-error"
          end
          backend.attribute("aria-describedby", described.join(' ')) unless described.empty?
        end
        @view.leave(Tag::Input)
        @view.open_with(Tag::Input, NamedTuple.new) do
          backend.attribute("type", "hidden")
          backend.attribute("name", key)
          backend.attribute("id", "#{id}-ticket")
          backend.attribute("value", current) if current
        end
        @view.leave(Tag::Input)
      end

      private def length(min_length, max_length) : Nil
        @view.backend.attribute("minlength", min_length.to_s) if min_length
        @view.backend.attribute("maxlength", max_length.to_s) if max_length
      end

      # The value of a field as sent or given; `nil` when there is none.
      private def current(key : String) : String?
        @values.fetch_all(key).first?
      end
    end
  end
end
