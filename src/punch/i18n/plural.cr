module Punch::I18n
  # Plural categories (CLDR), in the order the catalog stores a plural
  # message's forms.
  enum Category
    Zero
    One
    Two
    Few
    Many
    Other
  end

  # Punch's own table of plural rules for whole numbers: a small table
  # instead of CLDR. Each rule is named after the languages that share it; a
  # locale such as `pt-BR` uses its language's rule unless the table lists
  # the whole tag.
  #
  # Not covered: fractions, and CLDR's `many` for exact millions in
  # French, Spanish, Italian, Portuguese, and Catalan (rails-i18n leaves it
  # out too).
  module Plural
    enum Rule
      # en, de, …: one for 1.
      OneOther
      # fr, pt: one for 0 and 1.
      ZeroOneOther
      # ru, uk, be.
      EastSlavic
      # pl.
      Polish
      # cs, sk.
      WestSlavic
      # hr, sr, bs.
      SouthSlavic
      # lt.
      Lithuanian
      # lv.
      Latvian
      # ro.
      Romanian
      # sl.
      Slovenian
      # he.
      Hebrew
      # ar.
      Arabic
      # ja, zh, ko, …: one form.
      None
    end

    RULES = {
      "af" => Rule::OneOther, "bg" => Rule::OneOther, "ca" => Rule::OneOther, "da" => Rule::OneOther,
      "de" => Rule::OneOther, "el" => Rule::OneOther, "en" => Rule::OneOther, "es" => Rule::OneOther,
      "et" => Rule::OneOther, "eu" => Rule::OneOther, "fi" => Rule::OneOther, "gl" => Rule::OneOther,
      "hu" => Rule::OneOther, "it" => Rule::OneOther, "nb" => Rule::OneOther, "nl" => Rule::OneOther,
      "nn" => Rule::OneOther, "no" => Rule::OneOther, "sq" => Rule::OneOther, "sv" => Rule::OneOther,
      "tr" => Rule::OneOther,
      "fr" => Rule::ZeroOneOther, "pt" => Rule::ZeroOneOther, "pt-PT" => Rule::OneOther,
      "be" => Rule::EastSlavic, "ru" => Rule::EastSlavic, "uk" => Rule::EastSlavic,
      "pl" => Rule::Polish,
      "cs" => Rule::WestSlavic, "sk" => Rule::WestSlavic,
      "bs" => Rule::SouthSlavic, "hr" => Rule::SouthSlavic, "sr" => Rule::SouthSlavic,
      "lt" => Rule::Lithuanian, "lv" => Rule::Latvian, "ro" => Rule::Romanian,
      "sl" => Rule::Slovenian, "he" => Rule::Hebrew, "ar" => Rule::Arabic,
      "id" => Rule::None, "ja" => Rule::None, "ko" => Rule::None, "ms" => Rule::None,
      "th" => Rule::None, "vi" => Rule::None, "zh" => Rule::None,
    }

    # The rule for a locale tag; `nil` when the table has none.
    def self.rule?(locale : String) : Rule?
      RULES[locale]? || RULES[locale.partition('-')[0]]?
    end

    # The categories a rule needs a form for: those whole numbers reach,
    # and `other`, which CLDR always requires. `zero` is allowed in every
    # language as an override for 0.
    def self.categories(rule : Rule) : Array(Category)
      reached = (0_i64..200_i64).map { |number| category(rule, number) }.to_set
      Category.values.select { |value| value.other? || reached.includes?(value) }
    end

    # The category of the whole number *n*.
    def self.category(rule : Rule, n : Int) : Category
      CATEGORY[rule].call(n.to_i64.abs)
    end

    # Each rule, for a number from 0 up (CLDR's integer conditions).
    CATEGORY = {
      Rule::OneOther     => ->(n : Int64) { n == 1 ? Category::One : Category::Other },
      Rule::ZeroOneOther => ->(n : Int64) { n <= 1 ? Category::One : Category::Other },
      Rule::EastSlavic   => ->(n : Int64) { slavic(n) || Category::Many },
      Rule::Polish       => ->(n : Int64) { n == 1 ? Category::One : (few?(n) ? Category::Few : Category::Many) },
      Rule::WestSlavic   => ->(n : Int64) { n == 1 ? Category::One : (n.in?(2..4) ? Category::Few : Category::Other) },
      Rule::SouthSlavic  => ->(n : Int64) { slavic(n) || Category::Other },
      Rule::Lithuanian   => ->(n : Int64) { lithuanian(n) },
      Rule::Latvian      => ->(n : Int64) { latvian(n) },
      Rule::Romanian     => ->(n : Int64) { romanian(n) },
      Rule::Slovenian    => ->(n : Int64) { {Category::Other, Category::One, Category::Two, Category::Few, Category::Few}[n % 100]? || Category::Other },
      Rule::Hebrew       => ->(n : Int64) { {Category::Other, Category::One, Category::Two}[n]? || Category::Other },
      Rule::Arabic       => ->(n : Int64) { arabic(n) },
      Rule::None         => ->(_n : Int64) { Category::Other },
    }

    # 2–4, but not 12–14, in the last digits.
    private def self.few?(n : Int64) : Bool
      (n % 10).in?(2..4) && !(n % 100).in?(12..14)
    end

    # One for 1, 21, 31 (not 11), few for 2–4 (not 12–14); `nil` otherwise.
    private def self.slavic(n : Int64) : Category?
      return Category::Few if few?(n)

      Category::One if n % 10 == 1 && n % 100 != 11
    end

    private def self.lithuanian(n : Int64) : Category
      return Category::Other if (n % 100).in?(11..19)

      case n % 10
      when 1 then Category::One
      when 0 then Category::Other
      else        Category::Few
      end
    end

    private def self.latvian(n : Int64) : Category
      return Category::Zero if n % 10 == 0 || (n % 100).in?(11..19)

      n % 10 == 1 ? Category::One : Category::Other
    end

    private def self.romanian(n : Int64) : Category
      return Category::One if n == 1

      n == 0 || (n % 100).in?(2..19) ? Category::Few : Category::Other
    end

    private def self.arabic(n : Int64) : Category
      return {Category::Zero, Category::One, Category::Two}[n] if n <= 2
      return Category::Few if (n % 100).in?(3..10)

      (n % 100).in?(11..99) ? Category::Many : Category::Other
    end
  end
end
