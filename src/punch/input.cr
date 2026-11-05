require "./input/read"
require "./input/form"

module Punch
  # Marks an `Input` field that comes from the URL path, such as the
  # `invoice_id` in `/billing/invoices/:invoice_id/send`.
  annotation PathParam
  end

  # The typed input of an operation, parsed at the boundary.
  #
  # ```
  # struct Input
  #   include Punch::Input
  #
  #   @[Punch::PathParam]
  #   getter invoice_id : Invoices::ID
  #   getter recipient : Punch::Email
  #   getter note : String?     # optional
  #   getter copies : Int32 = 1 # optional, with a default
  # end
  #
  # Input.from_json(body, path_params) # => Input | Punch::Rejection
  # Input.from_query(query, path_params)
  # ```
  #
  # Three rules:
  # 1. Fields marked `@[Punch::PathParam]` come from the path. The others come
  #    from the JSON body (`from_json`, for Commands) or from the query string
  #    (`from_query`, for Queries). The router picks.
  # 2. A field is required unless its type is nilable or it has a default.
  # 3. Every error is collected, with its path, into one `Rejection`.
  #
  # Field types: `String`, `Bool`, `Int32`, `Int64`, `Float64`, `Time`
  # (RFC 3339), enums (by snake_case name), domain primitives
  # (`Punch::Primitive`), nested inputs, and arrays of these (repeated keys
  # in a query string). A query string carries a nested input in brackets,
  # `filter[status]=paid`, as a form body does; arrays of inputs only come
  # in JSON and forms. Any other type does not compile.
  #
  # Unknown fields are ignored, in a JSON body and in a query string alike, so
  # clients can send more than an input declares. A repeated key is rejected,
  # because parsers disagree on which value wins. In a query string an empty
  # value counts as absent, as HTML forms send it.
  #
  # An input may define its own `initialize` to be built in code as well.
  #
  # Rules across fields go in `check`, which runs once every field parsed:
  #
  # ```
  # def check(errors : Punch::Rejection::Collector) : Nil
  #   errors.add(Punch::Rejection::Path.new, Punch::Invalid.new("ends_before_start")) if ends_on < starts_on
  # end
  # ```
  module Input
    alias PathParams = Hash(String, String)

    macro included
      # The parsing constructors, declared in the type itself: a type that
      # defines an `initialize` of its own (a generated query `Filter` does,
      # to be built in code) would otherwise hide them.

      # :nodoc:
      def self.new(*, __punch_json pull : JSON::PullParser, __punch_path path : ::Punch::Input::PathParams?, __punch_errors errors : ::Punch::Rejection::Collector) : self
        instance = allocate
        instance.initialize(__punch_json: pull, __punch_path: path, __punch_errors: errors)
        instance
      end

      # :nodoc:
      def self.new(*, __punch_query query : URI::Params, __punch_path path : ::Punch::Input::PathParams?, __punch_errors errors : ::Punch::Rejection::Collector) : self
        instance = allocate
        instance.initialize(__punch_query: query, __punch_path: path, __punch_errors: errors)
        instance
      end

      # :nodoc:
      def self.new(*, __punch_form form : URI::Params, __punch_prefix prefix : String?, __punch_path path : ::Punch::Input::PathParams?, __punch_errors errors : ::Punch::Rejection::Collector) : self
        instance = allocate
        instance.initialize(__punch_form: form, __punch_prefix: prefix, __punch_path: path, __punch_errors: errors)
        instance
      end

      # Parses a JSON object. An empty body counts as `{}`.
      def self.from_json(body : String, path : ::Punch::Input::PathParams = ::Punch::Input::PathParams.new) : self | ::Punch::Rejection
        errors = ::Punch::Rejection::Collector.new
        pull = JSON::PullParser.new(body.blank? ? "{}" : body)
        unless pull.kind.begin_object?
          return ::Punch::Rejection.new(::Punch::Rejection::Path.new, ::Punch::Invalid.new("expected_object"))
        end

        result = __punch_read_json(pull, errors, path)
        raise JSON::ParseException.new("unexpected content after the object", *pull.location) unless pull.kind.eof?
        result.is_a?(self) ? result : ::Punch::Rejection.new(errors.errors)
      rescue ex : JSON::ParseException
        ::Punch::Rejection.new(::Punch::Rejection::Path.new, ::Punch::Invalid.new("malformed_json", line: ex.line_number, column: ex.column_number))
      end

      # Parses query parameters, such as `request.query_params`.
      def self.from_query(query : URI::Params, path : ::Punch::Input::PathParams = ::Punch::Input::PathParams.new) : self | ::Punch::Rejection
        errors = ::Punch::Rejection::Collector.new
        input = new(__punch_query: query, __punch_path: path, __punch_errors: errors)
        input.check(errors) if errors.empty?
        errors.empty? ? input : ::Punch::Rejection.new(errors.errors)
      end

      # Parses a form body (`application/x-www-form-urlencoded`), as a
      # browser sends it. As in a query string, an empty value counts as
      # absent and a key may not repeat; nested inputs use bracketed names
      # (`address[street]`, `lines[0][description]`).
      def self.from_form(form : URI::Params, path : ::Punch::Input::PathParams = ::Punch::Input::PathParams.new) : self | ::Punch::Rejection
        errors = ::Punch::Rejection::Collector.new
        input = new(__punch_form: form, __punch_prefix: nil, __punch_path: path, __punch_errors: errors)
        input.check(errors) if errors.empty?
        errors.empty? ? input : ::Punch::Rejection.new(errors.errors)
      end

      # :nodoc:
      def self.__punch_read_form(form : URI::Params, prefix : String, errors : ::Punch::Rejection::Collector) : self | ::Punch::Input::Read::Failed
        before = errors.size
        input = new(__punch_form: form, __punch_prefix: prefix, __punch_path: nil, __punch_errors: errors)
        input.check(errors) if errors.size == before
        errors.size == before ? input : ::Punch::Input::Read::Failed.new
      end

      # :nodoc:
      # Adds the fields that hold a value other than their default to
      # *params* (`URI::Params` or its builder), under *prefix*: how a link
      # or a GET form carries this input (`Page.href`, `View#filter_form`).
      # Path parameters are left out; the path carries them.
      def __punch_encode(params, prefix : String?) : Nil
        \{% for ivar in @type.instance_vars.reject(&.annotation(::Punch::PathParam)) %}
          \{% if ivar.has_default_value? %}
            unless @\{{ ivar.name }} == (\{{ ivar.default_value }})
              ::Punch::Input::Form.add(params, ::Punch::Input::Form.key(prefix, \{{ ivar.name.stringify }}), @\{{ ivar.name }})
            end
          \{% else %}
            ::Punch::Input::Form.add(params, ::Punch::Input::Form.key(prefix, \{{ ivar.name.stringify }}), @\{{ ivar.name }})
          \{% end %}
        \{% end %}
      end

      # The input's fields as an enum, so that a form names a field by a
      # symbol the compiler checks (`f.field :email`). Taken from the
      # getters, which is how fields are declared.
      macro finished
        \{% names = @type.methods.select { |method| method.args.empty? && method.body.is_a?(InstanceVar) }.map { |method| method.body.name.stringify[1..-1] }.uniq %}
        \{% unless names.empty? %}
          # :nodoc:
          enum PunchField
            \{% for name in names %}
              \{{ name.camelcase.id }}
            \{% end %}

            # The field's name in the input, such as `company_name`.
            def key : String
              case self
              \{% for name in names %}
                in \{{ name.camelcase.id }} then \{{ name }}
              \{% end %}
              end
            end
          end
        \{% end %}
      end

      # :nodoc:
      def self.__punch_read_json(pull : JSON::PullParser, errors : ::Punch::Rejection::Collector,
                                 path : ::Punch::Input::PathParams? = nil) : self | ::Punch::Input::Read::Failed
        before = errors.size
        input = new(__punch_json: pull, __punch_path: path, __punch_errors: errors)
        input.check(errors) if errors.size == before
        errors.size == before ? input : ::Punch::Input::Read::Failed.new
      end
    end

    # Rules across fields. Runs only when every field parsed; add errors to
    # *errors*, at a field or at `Punch::Rejection::Path.new` for the input as a whole.
    def check(errors : Rejection::Collector) : Nil
    end

    # Fields that fail are left uninitialized. The instance is then discarded
    # and the caller returns the rejection instead.
    def initialize(*, __punch_json pull : JSON::PullParser, __punch_path path : PathParams?, __punch_errors errors : Rejection::Collector)
      __punch_check_field_types
      {% begin %}
      {% fields = @type.instance_vars.reject(&.annotation(Punch::PathParam)) %}
      {% for ivar in fields %}
        %present{ivar.name} = false
        %seen{ivar.name} = false
        %value{ivar.name} = uninitialized {{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
      {% end %}
      pull.read_begin_object
      until pull.kind.end_object?
        key = pull.read_object_key
        case key
        {% for ivar in fields %}
          {% name = ivar.name.stringify %}
          {% type = ivar.type.union_types.reject { |member| member == Nil }.first %}
        when {{ name }}
          if %present{ivar.name}
            errors.add({{ name }}, Punch::Invalid.new("duplicate_field"))
            pull.skip
            next
          end
          %present{ivar.name} = true
          if pull.kind.null?
            pull.read_null
            {% if ivar.type.nilable? %}
              %seen{ivar.name} = true
              %value{ivar.name} = nil
            {% else %}
              errors.add({{ name }}, Punch::Invalid.new("required"))
            {% end %}
          else
            case %read = Punch::Input::Read.json({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, pull, errors.nested({{ name }}))
            in Punch::Invalid then errors.add({{ name }}, %read)
            in Punch::Input::Read::Failed
            in {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              %seen{ivar.name} = true
              %value{ivar.name} = %read
            end
          end
        {% end %}
        else
          pull.skip
        end
      end
      pull.read_end_object

      {% for ivar in fields %}
        if %seen{ivar.name}
          @{{ ivar.name }} = %value{ivar.name}
        elsif %present{ivar.name}
          __punch_unset({{ ivar.name }})
        else
          __punch_absent({{ ivar.name }})
        end
      {% end %}
      {% end %}
      __punch_read_path_params
    end

    def initialize(*, __punch_query query : URI::Params, __punch_path path : PathParams?, __punch_errors errors : Rejection::Collector)
      __punch_check_field_types
      {% begin %}
      {% for ivar in @type.instance_vars.reject(&.annotation(Punch::PathParam)) %}
        {% name = ivar.name.stringify %}
        {% type = ivar.type.union_types.reject { |member| member == Nil }.first %}
        {% if type < Array && type.type_vars.first < Punch::Input %}
          {% raise "Punch: #{@type}##{ivar.name} is an array of inputs, which a query string cannot carry. Parse #{@type} with from_json." %}
        {% end %}
        {% if type < Punch::Input %}
          # A nested input in brackets, as in a form body: `filter[status]`.
          if Punch::Input::Form.blank?(query, {{ name }})
            __punch_absent({{ ivar.name }})
          else
            case %nested = {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.__punch_read_form(query, {{ name }}, errors.nested({{ name }}))
            in Punch::Input::Read::Failed then __punch_unset({{ ivar.name }})
            in {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}                 then @{{ ivar.name }} = %nested
            end
          end
        {% elsif type < Array %}
          %raw = query.fetch_all({{ name }}).reject(&.empty?)
          %items = [] of {{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
          %failed = false
          %raw.each_with_index do |item, index|
            case %read = Punch::Input::Read.string({{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, item)
            in Punch::Invalid
              errors.add(Punch::Rejection::Path{ {{ name }}, index }, %read)
              %failed = true
            in {{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              %items << %read
            end
          end
          if %raw.empty?
            __punch_absent({{ ivar.name }})
          elsif %failed
            __punch_unset({{ ivar.name }})
          else
            @{{ ivar.name }} = %items
          end
        {% else %}
          %raw = query.fetch_all({{ name }}).reject(&.empty?)

          case %raw.size
          when 0
            __punch_absent({{ ivar.name }})
          when 1
            __punch_assign({{ ivar.name }}, Punch::Input::Read.string({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, %raw.first))
          else
            errors.add({{ name }}, Punch::Invalid.new("duplicate_field"))
            __punch_unset({{ ivar.name }})
          end
        {% end %}
      {% end %}
      {% end %}
      __punch_read_path_params
    end

    def initialize(*, __punch_form form : URI::Params, __punch_prefix prefix : String?, __punch_path path : PathParams?, __punch_errors errors : Rejection::Collector)
      __punch_check_field_types
      {% begin %}
      {% for ivar in @type.instance_vars.reject(&.annotation(Punch::PathParam)) %}
        {% name = ivar.name.stringify %}
        {% type = ivar.type.union_types.reject { |member| member == Nil }.first %}
        %key = Punch::Input::Form.key(prefix, {{ name }})
        {% if type < Punch::Input %}
          if Punch::Input::Form.blank?(form, %key)
            __punch_absent({{ ivar.name }})
          else
            case %read = {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.__punch_read_form(form, %key, errors.nested({{ name }}))
            in Punch::Input::Read::Failed then __punch_unset({{ ivar.name }})
            in {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}                 then @{{ ivar.name }} = %read
            end
          end
        {% elsif type < Array && type.type_vars.first < Punch::Input %}
          {% item = type.type_vars.first %}

          case %rows = Punch::Input::Form.rows(form, %key)
          in Punch::Invalid
            errors.add({{ name }}, %rows)
            __punch_unset({{ ivar.name }})
          in Array(Int32)
            if %rows.empty?
              __punch_absent({{ ivar.name }})
            else
              %items = [] of {{ item.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              %failed = false
              %rows.each do |index|
                case %read = {{ item.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.__punch_read_form(form, "#{%key}[#{index}]", errors.nested(Punch::Rejection::Path{ {{ name }}, index }))
                in Punch::Input::Read::Failed then %failed = true
                in {{ item.stringify.gsub(::Punch::NAME_STARTS, "::").id }}                 then %items << %read
                end
              end
              if %failed
                __punch_unset({{ ivar.name }})
              else
                @{{ ivar.name }} = %items
              end
            end
          end
        {% elsif type < Array %}
          %raw = form.fetch_all(%key).reject(&.empty?)
          %items = [] of {{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
          %failed = false
          %raw.each_with_index do |item, index|
            case %read = Punch::Input::Read.string({{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, item)
            in Punch::Invalid
              errors.add(Punch::Rejection::Path{ {{ name }}, index }, %read)
              %failed = true
            in {{ type.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
              %items << %read
            end
          end
          if %raw.empty?
            __punch_absent({{ ivar.name }})
          elsif %failed
            __punch_unset({{ ivar.name }})
          else
            @{{ ivar.name }} = %items
          end
        {% else %}
          %raw = form.fetch_all(%key).reject(&.empty?)

          case %raw.size
          when 0
            __punch_absent({{ ivar.name }})
          when 1
            __punch_assign({{ ivar.name }}, Punch::Input::Read.string({{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, %raw.first))
          else
            errors.add({{ name }}, Punch::Invalid.new("duplicate_field"))
            __punch_unset({{ ivar.name }})
          end
        {% end %}
      {% end %}
      {% end %}
      __punch_read_path_params
    end

    private macro __punch_absent(name)
      \{% begin %}
      \{% ivar = @type.instance_vars.find { |v| v.name.stringify == {{ name.stringify }} } %}
      \{% if ivar.has_default_value? %}
        # The ivar initializer has already set the default.
      \{% elsif ivar.type.nilable? %}
        @{{ name }} = nil
      \{% else %}
        errors.add({{ name.stringify }}, Punch::Invalid.new("required"))
        __punch_unset({{ name }})
      \{% end %}
      \{% end %}
    end

    # Leaves a field that failed to parse uninitialized; the instance is
    # discarded. A field with a default keeps it instead: assigning
    # `uninitialized` to a field that has an initializer makes the compiler
    # treat it as nilable (Crystal 1.21.1).
    private macro __punch_unset(name)
      \{% begin %}
      \{% ivar = @type.instance_vars.find { |v| v.name.stringify == {{ name.stringify }} } %}
      \{% unless ivar.has_default_value? %}
        @{{ name }} = uninitialized \{{ ivar.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
      \{% end %}
      \{% end %}
    end

    private macro __punch_assign(name, read)
      \{% begin %}
      \{% ivar = @type.instance_vars.find { |v| v.name.stringify == {{ name.stringify }} } %}
      case %read = {{ read }}
      in Punch::Invalid
        errors.add({{ name.stringify }}, %read)
        __punch_unset({{ name }})
      in \{{ ivar.type.union_types.reject { |member| member == Nil }.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
        @{{ name }} = %read
      end
      \{% end %}
    end

    private macro __punch_read_path_params
      \{% for ivar in @type.instance_vars.select(&.annotation(Punch::PathParam)) %}
        \{% type = ivar.type.union_types.reject { |member| member == Nil }.first %}
        \{% if type < Array || type < Punch::Input || ivar.type.nilable? %}
          \{% raise "Punch: path parameter #{@type}##{ivar.name} must be a single, required value, not #{ivar.type}." %}
        \{% end %}
        if (%params = path) && (%raw = %params[\{{ ivar.name.stringify }}]?)
          __punch_assign(\{{ ivar.name }}, Punch::Input::Read.string(\{{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, %raw))
        else
          errors.add(\{{ ivar.name.stringify }}, Punch::Invalid.new("required"))
          __punch_unset(\{{ ivar.name }})
        end
      \{% end %}
    end

    # Fails compilation, naming the field, when a field has a type that
    # Punch cannot parse.
    private def __punch_check_field_types : Nil
      {% for ivar in @type.instance_vars %}
        {% types = ivar.type.union_types.reject { |member| member == Nil } %}
        {% type = types.first %}
        {% item = type < Array ? type.type_vars.first : type %}
        {% supported = types.size == 1 && (
             [String, Bool, Int32, Int64, Float64, Time].includes?(item) ||
             (item < Enum && !item.annotation(Flags)) ||
             item < Punch::Input ||
             item.ancestors.any? { |a| a.name(generic_args: false) == "Punch::Primitive" }
           ) %}
        {% if item.name(generic_args: false) == "Punch::Upload::Key" %}
          {% raise "Punch: #{@type}##{ivar.name} takes a Punch::Upload::Key, the key of a stored file: a client could name another user's file. " +
                   "Take the ID of the record that holds the key and load it, or a Punch::Upload::Ticket for a new upload (lib/punch/docs/uploads.md)." %}
        {% end %}
        {% if item.name(generic_args: false) == "Punch::Upload::ScanState" %}
          {% raise "Punch: #{@type}##{ivar.name} takes a Punch::Upload::ScanState: a client could pass its own file as clean. " +
                   "Only the app's scanning job sets a state (lib/punch/docs/uploads.md)." %}
        {% end %}
        {% unless supported %}
          {% raise "Punch: #{@type}##{ivar.name} has type #{ivar.type}, which Punch::Input cannot parse.\n" +
                   "Use String, Bool, Int32, Int64, Float64, Time, an enum, a domain primitive (Punch::Primitive),\n" +
                   "a nested Punch::Input, or an Array of one of these. Make it nilable (`T?`) to make it optional." %}
        {% end %}
      {% end %}
    end
  end
end
