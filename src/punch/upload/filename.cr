module Punch::Upload
  # The extensions a file of each content type may carry, the usual one
  # first. A type without any (`application/octet-stream`) keeps the name
  # it came with.
  EXTENSIONS = {
    "application/pdf"                                                           => %w[pdf],
    "image/png"                                                                 => %w[png],
    "image/jpeg"                                                                => %w[jpg jpeg],
    "image/gif"                                                                 => %w[gif],
    "image/webp"                                                                => %w[webp],
    "image/avif"                                                                => %w[avif],
    "image/heic"                                                                => %w[heic heif],
    "text/plain"                                                                => %w[txt text log md],
    "text/csv"                                                                  => %w[csv],
    "application/zip"                                                           => %w[zip],
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"   => %w[docx],
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"         => %w[xlsx],
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => %w[pptx],
    "application/vnd.oasis.opendocument.text"                                   => %w[odt],
    "application/vnd.oasis.opendocument.spreadsheet"                            => %w[ods],
    "audio/mpeg"                                                                => %w[mp3],
    "video/mp4"                                                                 => %w[mp4 m4v],
    "application/octet-stream"                                                  => [] of String,
  }

  # The name a file had on the client's machine, to show and to download
  # under. It comes from the client, so it is cleaned: no directories, no
  # control or direction characters, no leading dots, at most 255 bytes,
  # with its extension kept. It names nothing in the storage (a `Key` does),
  # and never becomes a path or an argument of another program.
  struct Filename
    include Punch::Primitive(String)

    MAX_BYTES = 255
    # The longest name `parse` looks at. Input is parsed before a request is
    # authenticated, so what it costs must not grow with what a stranger sends.
    MAX_RAW_BYTES = 4096
    # Characters that change how a name reads without being seen: the
    # format characters, among them the bidirectional controls that make
    # `fdp.exe` read `exe.pdf`, and the default-ignorable code points. Those
    # are listed, not named as a property: a property needs PCRE2 10.40, and
    # a stored name is parsed again on every read, so what this removes must
    # not move with the library.
    INVISIBLE = /[\p{Cf}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{2065}\x{3164}\x{FE00}-\x{FE0F}\x{FFA0}\x{FFF0}-\x{FFF8}\x{1BCA0}-\x{1BCA3}\x{1D173}-\x{1D17A}\x{E0000}-\x{E0FFF}]/
    # Control characters and line breaks, of any script, and runs of space.
    BREAKS = /[\p{Cc}\p{Zl}\p{Zp}\s]+/

    def self.json_schema
      {minLength: 1, maxLength: MAX_RAW_BYTES}
    end

    def self.parse(raw : String) : self | Invalid
      return Invalid.new("invalid_filename") if raw.bytesize > MAX_RAW_BYTES

      name = clean(raw)
      name.empty? ? Invalid.new("invalid_filename") : new(name)
    end

    # What a type Punch does not take gets: no name that opens as anything.
    UNKNOWN_TYPE = %w[bin]

    # The name of a file that came without one.
    def self.default(content_type : String) : self
      extension = EXTENSIONS[content_type]?.try(&.first?)
      new(extension ? "file.#{extension}" : "file")
    end

    # This name for a file of *content_type*: one that opens as what the
    # check found. A PDF called `report.html` would otherwise be saved as
    # a page, and run as one on the machine that opens it, so it becomes
    # `report.html.pdf`.
    def for(content_type : String) : self
      extensions = EXTENSIONS[content_type]? || UNKNOWN_TYPE
      return self if extensions.empty? || extensions.includes?(Filename.extension(value).downcase)

      Filename.parse("#{value}.#{extensions.first}").as(Filename)
    end

    # Never whole: a name can be personal data.
    def inspect(io : IO) : Nil
      io << "Punch::Upload::Filename(…)"
    end

    # :nodoc:
    def self.extension(name : String) : String
      stem, dot, extension = name.rpartition('.')
      stem.empty? || dot.empty? ? "" : extension
    end

    private def self.clean(raw : String) : String
      text = raw.scrub("")
      separator = [text.rindex('/'), text.rindex('\\')].compact.max?
      name = separator ? text[(separator + 1)..] : text
      name = name.gsub(INVISIBLE, "").unicode_normalize(:nfc)
      name = name.gsub(BREAKS, " ").strip
      fit(name.lstrip(". ").rstrip(". "))
    end

    # *name* in `MAX_BYTES`, shortened before its extension, on a character.
    private def self.fit(name : String) : String
      return name if name.bytesize <= MAX_BYTES

      extension = extension(name)
      tail = extension.empty? || extension.bytesize > 32 ? "" : ".#{extension}"
      stem = name.byte_slice(0, MAX_BYTES - tail.bytesize).scrub("")
      "#{stem.rstrip(". ")}#{tail}"
    end
  end
end
