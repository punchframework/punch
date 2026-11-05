module Punch
  # The language a request, a job, or a mail is rendered in: one of the
  # app's locales, from its catalog. Passed explicitly: a view has
  # `v.locale`, an operation takes `locale : Punch::Locale` in `call`, a job
  # builds one from the recipient's stored tag with
  # `Punch::I18n.locale(tag)`.
  #
  # `locale.t` is the app's typed translations, once the app declares
  # them with `Punch.translations` (docs/translations.md); the formats
  # (`date`, `time`, `number`, `money`) work without.
  struct Locale
    getter catalog : I18n::Catalog
    getter index : Int32

    def initialize(@catalog : I18n::Catalog, @index : Int32)
    end

    # The tag, such as `en` or `pt-BR`.
    def code : String
      @catalog.locales[@index]
    end

    def to_s(io : IO) : Nil
      io << code
    end

    def ==(other : Locale) : Bool
      @index == other.index && @catalog.same?(other.catalog)
    end

    # :nodoc:
    # A message without arguments; generated accessors call this.
    def message(slot : Int32) : String
      @catalog.text(@index, slot)
    end

    # :nodoc:
    # A message with its arguments filled in.
    def message(slot : Int32, args : NamedTuple) : String
      I18n.interpolate(@catalog.text(@index, slot), args)
    end

    # :nodoc:
    # The form of a plural message for *count*: `zero` for 0 where the
    # message has one, otherwise the category of the locale's rule.
    def plural(slot : Int32, count : Int, args : NamedTuple) : String
      I18n.interpolate(plural_template(slot, count), args)
    end

    # The message at *key* with *params* filled in, `nil` when no locale
    # has it. For keys known only at runtime, such as an error's code;
    # code that knows its key uses the typed accessors (`locale.t`).
    def translate?(key : String, params : Hash(String, Invalid::Param) = {} of String => Invalid::Param) : String?
      entry = @catalog.entries[key]? || return
      template = case entry.kind
                 in .message? then @catalog.text?(@index, entry.slot)
                 in .plural?
                   count = params["count"]?
                   count.is_a?(Int64) ? plural_template(entry.slot, count) : @catalog.text?(@index, entry.slot + I18n::Category::Other.value)
                 in .list? then nil
                 end
      template.try { |text| I18n.interpolate(text, params) }
    end

    # The items of a list such as `date.month_names`; `nil` for an item
    # the file left empty (`~`).
    def list(key : String) : Array(String?)
      entry = @catalog.entries[key]?
      raise KeyError.new("#{key} is not a list in the catalog") unless entry && entry.kind.list?
      own = @catalog.texts[@index]
      index = (0...entry.size).any? { |offset| own[entry.slot + offset]? } ? @index : 0
      (0...entry.size).map { |offset| @catalog.texts[index][entry.slot + offset]? }
    end

    # The message for a rejection's error: `errors.<code>`, else Punch's
    # `punch.errors.<code>`; `nil` when neither exists.
    def error?(code : String, params : Hash(String, Invalid::Param) = {} of String => Invalid::Param) : String?
      translate?("errors.#{code}", params) || translate?("punch.errors.#{code}", params)
    end

    # The message for a whole problem: `problems.<code>`, else Punch's
    # `punch.problems.<code>`.
    def problem?(code : String, params : Hash(String, Invalid::Param) = {} of String => Invalid::Param) : String?
      translate?("problems.#{code}", params) || translate?("punch.problems.#{code}", params)
    end

    # A form field's label: `fields.<name>`, else Punch's default made
    # from the name (`company_name` is "Company name", `customer_id`
    # "Customer").
    def field(name : String) : String
      translate?("fields.#{name}") || I18n.humanize(name)
    end

    private def plural_template(slot : Int32, count : Int) : String
      other = I18n::Category::Other.value
      index = @catalog.texts[@index][slot + other]? ? @index : 0
      texts = @catalog.texts[index]
      if count == 0 && (zero = texts[slot]?)
        return zero
      end

      category = I18n::Plural.category(@catalog.rules[index], count)
      texts[slot + category.value]? || texts[slot + other]? || raise KeyError.new("no plural form at slot #{slot}")
    end
  end
end
