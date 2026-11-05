module Punch
  # Text with at least one visible character. Surrounding whitespace is
  # removed and the text is normalized to NFC.
  struct NonEmptyString
    include Primitive(String)

    # At least one character that is not whitespace.
    def self.json_schema
      {pattern: "\\S"}
    end

    def self.parse(raw : String) : self | Invalid
      case text = Text.normalize(raw)
      in Invalid then text
      in String  then text.empty? ? Invalid.new("blank") : new(text)
      end
    end
  end
end
