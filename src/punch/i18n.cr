require "./i18n/plural"
require "./i18n/catalog"
require "./i18n/locale"
require "./i18n/formats"
require "./i18n/own.gen"

module Punch
  # Translations and formats (docs/translations.md).
  #
  # Locale files are YAML in `config/locales/`; `punch
  # i18n:generate` turns them, with Punch's own messages, into a committed
  # file of typed accessors and the catalog. Rejections carry codes, which
  # are rendered in the request's locale at the edge. An app without
  # locale files uses Punch's catalog: English and German.
  module I18n
    # What a message's `%{name}` takes.
    alias Arg = String | Int32 | Int64 | Float64

    # The app's catalog: Punch's own until the app declares its
    # translations (`Punch.translations`), which replaces this method.
    def self.catalog : Catalog
      OWN
    end

    # The default locale: the catalog's first.
    def self.default : Locale
      catalog.default
    end

    # The locale for a stored tag (a user's, a mail recipient's): the tag,
    # its language, or the default.
    def self.locale(tag : String?) : Locale
      catalog.locale(tag)
    end

    # The locale a request asks for in `Accept-Language` (RFC 9110,
    # 12.5.4): the highest `q` first, a tag matched exactly, else by its
    # language (`de-AT` finds `de`, `de` finds `de-CH`); the default when
    # nothing matches.
    def self.negotiate(header : String?, catalog : Catalog = self.catalog) : Locale
      return catalog.default unless header

      ranges = [] of {String, Float64, Int32}
      header.split(',').each_with_index do |part, position|
        tag, *parameters = part.split(';')
        tag = tag.strip
        next if tag.empty?
        q = 1.0
        parameters.each do |parameter|
          name, _, value = parameter.partition('=')
          q = value.strip.to_f? || 0.0 if name.strip.downcase == "q"
        end
        ranges << {tag, q, position} if q > 0
      end
      ranges.sort_by! { |_, weight, position| {-weight, position} }
      ranges.each do |tag, _, _|
        return catalog.default if tag == "*"
        if found = catalog.locale?(tag) || catalog.locale?(tag.partition('-')[0])
          return found
        end

        language = tag.partition('-')[0].downcase
        catalog.locales.each_with_index do |code, index|
          return Locale.new(catalog, index) if code.downcase.starts_with?("#{language}-")
        end
      end
      catalog.default
    end

    # Renders the rest of the request in the actor's stored locale, when
    # the app has it (the tag or its language); otherwise the request
    # keeps the one `Accept-Language` chose.
    def self.prefer(context : HTTP::Context, tag : LocaleTag?) : Nil
      tag = tag.try(&.to_s) || return
      found = catalog.locale?(tag) || catalog.locale?(tag.partition('-')[0])
      context.locale = found if found
    end

    # *template* with each `%{name}` replaced by the argument of that
    # name; `%%{` writes `%{`. A name without an argument stays as it is.
    def self.interpolate(template : String, args : NamedTuple | Hash(String, Invalid::Param)) : String
      return template unless template.includes?("%{")

      bytes = template.to_slice
      String.build(bytes.size + 16) do |io|
        i = 0
        while i < bytes.size
          if bytes[i] == PERCENT && bytes[i + 1]? == PERCENT && bytes[i + 2]? == OPEN
            io << "%{"
            i += 3
            next
          end
          if bytes[i] == PERCENT && bytes[i + 1]? == OPEN && (close = template.byte_index(CLOSE, i + 2))
            if value = argument(args, template.byte_slice(i + 2, close - i - 2))
              io << value
            else
              io.write(bytes[i..close])
            end
            i = close + 1
            next
          end
          following = template.byte_index(PERCENT, i + 1) || bytes.size
          io.write(bytes[i...following])
          i = following
        end
      end
    end

    private PERCENT = '%'.ord.to_u8
    private OPEN    = '{'.ord.to_u8
    private CLOSE   = '}'.ord.to_u8

    private def self.argument(args : NamedTuple, name : String) : String?
      args.each { |key, value| return value.to_s if key.to_s == name }
      nil
    end

    private def self.argument(args : Hash(String, Invalid::Param), name : String) : String?
      args[name]?.try(&.to_s)
    end

    # A field name as a label: `company_name` is "Company name",
    # `customer_id` "Customer".
    def self.humanize(name : String) : String
      name.chomp("_id").tr("_", " ").capitalize
    end
  end

  # A locale tag as stored with a user: a language, optionally with a
  # region or script (`de`, `pt-BR`, `zh-Hant`). Checked for form only:
  # whether the app has the locale is decided where it is used
  # (`Punch::I18n.locale` falls back to the default).
  struct LocaleTag
    include Primitive(String)

    FORMAT = /\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/

    def self.json_schema
      {pattern: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", maxLength: 35}
    end

    def self.parse(raw : String) : self | Invalid
      raw.size <= 35 && FORMAT.matches?(raw) ? new(raw) : Invalid.new("invalid_locale")
    end
  end

  # Declares the app's translations, the type `punch i18n:generate`
  # wrote from `config/locales/` (docs/translations.md):
  #
  # ```
  # # app/translations.cr; the generator writes app/translations.gen.cr
  # Punch.translations Invoicing::Translations, default: "en"
  # ```
  #
  # Every locale then has `t`, the typed accessors:
  # `v.t.invoices.sent(number: number)`. *default* must be the locale the
  # file was generated with; the generator reads it from here.
  macro translations(type, default = "en")
    {% raise "Punch.translations #{type}: the default locale must be a string literal such as \"en\"" unless default.is_a?(StringLiteral) %}

    struct ::Punch::Locale
      # The app's translations in this locale.
      def t : {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}
        {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.new(self)
      end
    end

    module ::Punch::I18n
      def self.catalog : ::Punch::I18n::Catalog
        {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}::CATALOG
      end
    end

    {% if type.resolve? %}
      {% generated = type.resolve.constant("DEFAULT") %}
      {% raise "Punch.translations #{type}, default: #{default}: #{type} was generated with the default locale #{generated}. Run `punch i18n:generate` (lib/punch/docs/translations.md)." unless generated == default %}
    {% end %}
  end
end
