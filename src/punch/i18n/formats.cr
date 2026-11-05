module Punch::I18n
  # The named formats every locale defines for dates and times:
  # `date.formats.default`, `.short`, `.long`, and the same under
  # `time.formats`.
  enum Format
    Default
    Short
    Long
  end
end

module Punch
  struct Locale
    # A date in this locale's format: `date.formats.<format>`, a
    # `strftime` pattern whose month and day names (`%B %b %A %a`) come
    # from `date.month_names` and friends.
    #
    # ```
    # locale.date(invoice.due_at)        # => "2026-11-12" (en), "12.11.2026" (de)
    # locale.date(invoice.due_at, :long) # => "November 12, 2026", "12. November 2026"
    # ```
    #
    # Converts nothing: pass the time in the zone to show it in
    # (`time.in(location)`), from the standard library.
    def date(time : Time, format : I18n::Format = :default) : String
      strftime(time, format_pattern("date", format))
    end

    # A date and time in this locale's format: `time.formats.<format>`,
    # with `%p`/`%P` from `time.am` and `time.pm`.
    def time(time : Time, format : I18n::Format = :default) : String
      strftime(time, format_pattern("time", format))
    end

    # *time* by a `strftime` pattern of the caller's, with this locale's
    # month and day names and AM/PM.
    def strftime(time : Time, pattern : String) : String
      localized = String.build do |io|
        reader = Char::Reader.new(pattern)
        while reader.has_next?
          char = reader.current_char
          reader.next_char
          unless char == '%'
            io << char
            next
          end
          flags = ""
          while reader.current_char.in?('-', '^', '_', '0')
            flags += reader.current_char
            reader.next_char
          end
          directive = reader.current_char
          reader.next_char
          name = name(time, directive)
          if name
            name = name.upcase if flags.includes?('^')
            io << name.gsub('%', "%%")
          else
            io << '%' << flags << directive
          end
        end
      end
      time.to_s(localized)
    end

    # A number with this locale's separator and delimiter
    # (`number.format`): `1,234.5` (en), `1.234,5` (de). *precision*
    # rounds to that many decimals; without it a `Float` keeps
    # `number.format.precision` decimals and an integer none.
    def number(value : Int, precision : Int32? = nil) : String
      separator, delimiter = number_marks("number.format")
      value.format(separator, delimiter, decimal_places: precision)
    end

    # :ditto:
    def number(value : Float, precision : Int32? = nil) : String
      separator, delimiter = number_marks("number.format")
      places = precision || translate?("number.format.precision").try(&.to_i?) || 3
      value.format(separator, delimiter, decimal_places: places)
    end

    # An amount with its currency (`number.currency.format`): as many
    # decimals as the currency has minor units (ISO 4217), the locale's
    # marks and pattern (`%u%n`, `%n %u`), and as the unit
    # `punch.currencies.<CODE>` where the locale names one, else the code.
    #
    # ```
    # locale.money(Punch::Money.new(125000), eur) # => "€1,250.00" (en), "1.250,00 €" (de)
    # ```
    def money(amount : Money, currency : Currency) : String
      separator, delimiter = number_marks("number.currency.format")
      places = currency.minor_unit
      scale = 10_i64 ** places
      whole, fraction = amount.value.abs.divmod(scale)
      digits = whole.format(separator, delimiter)
      digits += "#{separator}#{fraction.to_s.rjust(places, '0')}" if places > 0
      unit = translate?("punch.currencies.#{currency}") || currency.to_s
      pattern = translate?("number.currency.format.format") || "%u %n"
      if amount.negative?
        pattern = translate?("number.currency.format.negative_format") || "-#{pattern}"
      end
      pattern.gsub("%n", digits).gsub("%u", unit)
    end

    # The locale's word for a `strftime` directive that writes one, or
    # `nil` for the others, which `Time#to_s` writes.
    private def name(time : Time, directive : Char) : String?
      case directive
      when 'B' then names("date.month_names")[time.month]?
      when 'b' then names("date.abbr_month_names")[time.month]?
      when 'A' then names("date.day_names")[time.day_of_week.value % 7]?
      when 'a' then names("date.abbr_day_names")[time.day_of_week.value % 7]?
      when 'p', 'P'
        translate?(time.hour < 12 ? "time.am" : "time.pm").try { |text| directive == 'p' ? text.downcase : text }
      end
    end

    private def format_pattern(scope : String, format : I18n::Format) : String
      key = "#{scope}.formats.#{format.to_s.downcase}"
      translate?(key) || raise KeyError.new("#{key} is missing from the catalog")
    end

    private def names(key : String) : Array(String?)
      @catalog.entries[key]?.try(&.kind.list?) ? list(key) : [] of String?
    end

    private def number_marks(scope : String) : {String, String}
      separator = translate?("#{scope}.separator") || translate?("number.format.separator") || "."
      delimiter = translate?("#{scope}.delimiter") || translate?("number.format.delimiter") || ","
      {separator, delimiter}
    end
  end
end
