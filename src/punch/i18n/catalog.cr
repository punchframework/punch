module Punch::I18n
  # Every message of every locale, as `punch i18n:generate` writes it. Typed
  # accessors read slots by number; rejections, field labels, and formats
  # look keys up by name.
  #
  # A message is one slot; a plural message six, one per `Category`; a
  # list (`date.month_names`) one per item. A slot is `nil` where the
  # locale lacks the text: the default locale's is used instead, which the
  # generator guarantees to exist.
  class Catalog
    enum Kind
      Message
      Plural
      List
    end

    record Entry, slot : Int32, kind : Kind, size : Int32 = 1

    # Locale tags, the default first.
    getter locales : Array(String)
    getter entries : Hash(String, Entry)
    # Per locale, per slot.
    getter texts : Array(Array(String?))
    getter rules : Array(Plural::Rule)
    @by_tag : Hash(String, Int32)

    def initialize(@locales : Array(String), @entries : Hash(String, Entry), @texts : Array(Array(String?)))
      raise ArgumentError.new("a catalog needs a locale") if locales.empty?
      raise ArgumentError.new("one text list per locale") unless texts.size == locales.size
      @rules = locales.map { |tag| Plural.rule?(tag) || raise ArgumentError.new("no plural rule for #{tag}") }
      @by_tag = locales.each_with_index.to_h { |tag, index| {tag.downcase, index} }
    end

    def default : Locale
      Locale.new(self, 0)
    end

    # The locale *tag* names exactly (case-insensitive), or `nil`.
    def locale?(tag : String) : Locale?
      @by_tag[tag.downcase]?.try { |index| Locale.new(self, index) }
    end

    # The locale for a stored preference such as a user's or a mail
    # recipient's: *tag*, or its language (`de` for `de-AT`), or the
    # default.
    def locale(tag : String?) : Locale
      return default unless tag

      locale?(tag) || locale?(tag.partition('-')[0]) || default
    end

    # The text of *slot* in locale *index*, else in the default locale.
    def text(index : Int32, slot : Int32) : String
      @texts[index][slot]? || @texts[0][slot]? || raise KeyError.new("no text at slot #{slot}")
    end

    # Like `text`, `nil` when neither locale has one.
    def text?(index : Int32, slot : Int32) : String?
      @texts[index][slot]? || @texts[0][slot]?
    end
  end
end
