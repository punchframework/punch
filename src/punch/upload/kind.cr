module Punch::Upload
  # The rules of a kind of upload: the largest file and the content types
  # it takes.
  #
  # ```
  # @[Punch::Upload::Rules(max_size: 10_000_000, types: ["application/pdf", "image/png", "image/jpeg"])]
  # struct Expenses::Receipts::Scan
  #   include Punch::Upload::Kind
  # end
  # ```
  #
  # With `scan: true`, the app scans these files: a claimed one starts
  # `pending`, and Punch links to it only once it is `clean`
  # (`Punch::Upload::ScanState`).
  #
  # *max_size* is an integer literal in bytes, at most 5 GB (one `PUT` and
  # one copy in S3). *types* come from `TYPES`: Punch checks each file's
  # first bytes against its declared type before the app may record it.
  annotation Rules
  end

  # What Punch knows about a content type it accepts: the first bytes a
  # file of the type starts with, and whether browsers may show it from
  # the storage (`inline`) or only download it (`attachment`).
  record TypeRule, inline : Bool, check : Proc(Bytes, Bool)

  # Every content type an upload may declare. Types that run script in a
  # browser (HTML, SVG, XML, JavaScript) are not among them: a file the
  # storage serves runs in the storage's origin, and Punch does not hand
  # out such files. `application/octet-stream` takes any bytes and is
  # always downloaded, never shown.
  TYPE_NAMES = ["application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif",
                "image/heic", "text/plain", "text/csv", "application/zip",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                "application/vnd.oasis.opendocument.text", "application/vnd.oasis.opendocument.spreadsheet",
                "audio/mpeg", "video/mp4", "application/octet-stream"]

  # How many bytes from the start of a file the check reads.
  SNIFF_BYTES = 512

  # The rule of each type in `TYPE_NAMES`.
  TYPES = begin
    zip = ->(bytes : Bytes) { Upload.starts?(bytes, "PK\u{3}\u{4}") }
    text = ->(bytes : Bytes) { Upload.text?(bytes) }
    {
      "application/pdf"                                                           => TypeRule.new(true, ->(bytes : Bytes) { Upload.starts?(bytes, "%PDF-") }),
      "image/png"                                                                 => TypeRule.new(true, ->(bytes : Bytes) { Upload.starts?(bytes, "\x89PNG\r\n\x1A\n") }),
      "image/jpeg"                                                                => TypeRule.new(true, ->(bytes : Bytes) { bytes.size >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF }),
      "image/gif"                                                                 => TypeRule.new(true, ->(bytes : Bytes) { Upload.starts?(bytes, "GIF87a") || Upload.starts?(bytes, "GIF89a") }),
      "image/webp"                                                                => TypeRule.new(true, ->(bytes : Bytes) { Upload.starts?(bytes, "RIFF") && Upload.at?(bytes, 8, "WEBP") }),
      "image/avif"                                                                => TypeRule.new(true, ->(bytes : Bytes) { Upload.brand?(bytes, %w[avif avis]) }),
      "image/heic"                                                                => TypeRule.new(false, ->(bytes : Bytes) { Upload.brand?(bytes, %w[heic heix heim heis mif1 msf1]) }),
      "text/plain"                                                                => TypeRule.new(false, text),
      "text/csv"                                                                  => TypeRule.new(false, text),
      "application/zip"                                                           => TypeRule.new(false, zip),
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"   => TypeRule.new(false, zip),
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"         => TypeRule.new(false, zip),
      "application/vnd.openxmlformats-officedocument.presentationml.presentation" => TypeRule.new(false, zip),
      "application/vnd.oasis.opendocument.text"                                   => TypeRule.new(false, zip),
      "application/vnd.oasis.opendocument.spreadsheet"                            => TypeRule.new(false, zip),
      "audio/mpeg"                                                                => TypeRule.new(false, ->(bytes : Bytes) { Upload.starts?(bytes, "ID3") || (bytes.size >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) }),
      "video/mp4"                                                                 => TypeRule.new(false, ->(bytes : Bytes) { Upload.at?(bytes, 4, "ftyp") }),
      "application/octet-stream"                                                  => TypeRule.new(false, ->(_bytes : Bytes) { true }),
    }
  end

  # The largest *max_size*: S3 takes at most 5 GB in one `PUT`, and copies
  # at most that in one request.
  MAX_SIZE = 5_000_000_000_i64

  # A kind of upload, declared with `@[Punch::Upload::Rules]`. Its name,
  # in object keys and in `punch_uploads`, is the type's path in lowercase
  # with dots (`expenses.receipts.scan`): renaming the type leaves its
  # stored files under the old name, which `Key` still reads.
  module Kind
    macro included
      macro finished
        \{% rules = @type.annotation(::Punch::Upload::Rules) %}
        \{% unless rules %}
          \{% @type.raise "#{@type} is a kind of upload, so it has @[Punch::Upload::Rules(max_size: 10_000_000, types: [\"application/pdf\"])] (lib/punch/docs/uploads.md)." %}
        \{% end %}
        \{% max = rules[:max_size] %}
        \{% unless max.is_a?(NumberLiteral) && max > 0 && max <= ::Punch::Upload::MAX_SIZE %}
          \{% rules.raise "@[Punch::Upload::Rules] on #{@type}: max_size: is the largest file in bytes, an integer literal from 1 to 5_000_000_000, such as 10_000_000, not #{max}." %}
        \{% end %}
        \{% scanned = rules[:scan] %}
        \{% unless scanned == nil || scanned.is_a?(BoolLiteral) %}
          \{% rules.raise "@[Punch::Upload::Rules] on #{@type}: scan: is true or false, a literal" %}
        \{% end %}
        \{% types = rules[:types] %}
        \{% unless types.is_a?(ArrayLiteral) && !types.empty? && types.all?(&.is_a?(StringLiteral)) %}
          \{% rules.raise "@[Punch::Upload::Rules] on #{@type}: types: is an array of content types, such as [\"application/pdf\", \"image/png\"], not #{types}." %}
        \{% end %}
        \{% for type in types %}
          \{% unless ::Punch::Upload::TYPE_NAMES.includes?(type) %}
            \{% type.raise "@[Punch::Upload::Rules] on #{@type}: Punch does not take #{type}. It takes the types whose first bytes it can check: #{::Punch::Upload::TYPE_NAMES.join(", ").id}. Types that run script in a browser (HTML, SVG, XML, JavaScript) are never taken; upload such files as application/octet-stream, which is always downloaded (lib/punch/docs/uploads.md)." %}
          \{% end %}
        \{% end %}

        # The kind's name in object keys and `punch_uploads`. :nodoc:
        PUNCH_UPLOAD_NAME = \{{ @type.stringify.gsub(/^::/, "").gsub(/\(.*$/, "").split("::").map(&.underscore).join(".") }}

        # The kind's types for a file control's `accept`:
        # `f.field :scan, accept: Scan.upload_accept, data: {punch_upload: GrantScan.path}`.
        def self.upload_accept : String
          \{{ types.join(",") }}
        end

        # The kind's rules.
        def self.upload_rules : ::Punch::Upload::KindRules
          ::Punch::Upload::KindRules.new(PUNCH_UPLOAD_NAME, (\{{ max }}).to_i64, \{{ types }} of String, \{{ scanned == true }})
        end
      end
    end
  end

  # The rules of a kind, at run time.
  record KindRules, name : String, max_size : Int64, types : Array(String), scan : Bool = false

  # The rules of every kind in the binary, by name.
  def self.kinds : Hash(String, KindRules)
    @@kinds ||= begin
      kinds = {} of String => KindRules
      {% for kind in Kind.includers %}
        {% unless kind.abstract? || kind.module? %}
          {{ kind.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.upload_rules.tap { |rules| kinds[rules.name] = rules }
        {% end %}
      {% end %}
      kinds
    end
  end

  @@kinds : Hash(String, KindRules)?

  # Whether the binary declares a kind of upload.
  def self.used? : Bool
    {{ !Kind.includers.reject { |kind| kind.abstract? || kind.module? }.empty? }}
  end

  # :nodoc:
  def self.starts?(bytes : Bytes, prefix : String) : Bool
    at?(bytes, 0, prefix)
  end

  # :nodoc:
  def self.at?(bytes : Bytes, offset : Int32, text : String) : Bool
    expected = text.to_slice
    bytes.size >= offset + expected.size && bytes[offset, expected.size] == expected
  end

  # An ISO base media file (`ftyp` box) whose major brand is one of *brands*.
  # :nodoc:
  def self.brand?(bytes : Bytes, brands : Array(String)) : Bool
    at?(bytes, 4, "ftyp") && brands.any? { |brand| at?(bytes, 8, brand) }
  end

  # Text: UTF-8 without NUL bytes or other control characters but tab,
  # line feed, carriage return, and form feed. When *bytes* are the first
  # `SNIFF_BYTES` of a longer file, the last character may be cut off.
  # :nodoc:
  def self.text?(bytes : Bytes) : Bool
    return false if bytes.any? { |byte| byte < 0x20 && !byte.in?(0x09_u8, 0x0A_u8, 0x0C_u8, 0x0D_u8) }
    return true if String.new(bytes).valid_encoding?
    return false if bytes.size < SNIFF_BYTES

    # A character cut off at the end: a lead byte and fewer continuation
    # bytes than it announces.
    (1..3).any? do |cut|
      start = bytes.size - cut
      bytes[start] >= 0xC0 && bytes[start + 1..].all? { |byte| byte & 0xC0 == 0x80 } &&
        String.new(bytes[0, start]).valid_encoding?
    end
  end
end
