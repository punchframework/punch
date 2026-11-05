module Punch::Upload
  # A link was asked for a file of a scanned kind that the scan has not
  # passed, or by its bare key, which says nothing of a scan. Use `url?` or
  # `href?` where a file may be waiting.
  class NotServable < Exception
    def initialize(key : Key, state : ScanState? = nil)
      super("#{key} is #{state || "not known to be scanned"}: only a clean file of a scanned kind is served")
    end
  end

  # What every kept file does.
  module Kept
    abstract def scan_state : ScanState?

    # Whether Punch links to the file: the scan passed it, or it has no state
    # and its kind is not scanned. A file with no state in a scanned kind is
    # not servable: it may be from before the kind was scanned, and nothing
    # has looked at it.
    def servable? : Bool
      state = scan_state
      state ? state.clean? : !Upload.scanned_kind?(key)
    end

    # This file with the scan's result, for the app's scanning job to save.
    def scanned(state : ScanState) : self
      copy_with(scan_state: state).as(self)
    end
  end

  # A file the app claimed (`Punch::Upload.claim`): checked, and its own
  # from now on. Keep it whole, as a group of columns of the record it
  # belongs to:
  #
  # ```
  # scan: {type: Punch::Upload::File, columns: "file_"}
  # ```
  #
  # `Punch::Upload.href(file)` shows it, and
  # `Punch::Upload.href(file, download: true)` saves it under its name.
  struct File
    include Kept
  end

  # A `File` whose name is personal data. The same columns, with
  # `<prefix>filename` an encrypted `BLOB`, so `filename` is a
  # `Punch::Secret`. Its name is in no URL unless the app passes one: a URL
  # reaches the page, the browser's history, and the storage's logs.
  struct PrivateFile
    include Kept

    # *file*, as a claim returns it, for a private column.
    def self.of(file : File) : self
      build(key: file.key, filename: Punch::Secret.new(file.filename), size: file.size, content_type: file.content_type,
        scan_state: file.scan_state, delete_after: file.delete_after).as(self)
    end
  end

  # A `File` that is an image, with what a page needs to show it. Punch
  # does not read images: *width* and *height* are the app's to set, from
  # its own job or its client, and stay `nil` until then.
  struct ImageFile
    include Kept

    # *file* as an image; `not_an_image` when its type is not one.
    def self.of(file : File, *, alt : Punch::NonEmptyString? = nil, width : Int64? = nil, height : Int64? = nil) : self | Invalid
      build(key: file.key, filename: file.filename, size: file.size, content_type: file.content_type,
        scan_state: file.scan_state, delete_after: file.delete_after, width: width, height: height, alt: alt)
    end

    def self.check(value : self) : Invalid?
      Upload.check_image(value.content_type, value.width, value.height, value.alt.try(&.value))
    end
  end

  # A `PrivateFile` that is an image: its alt text describes it, so that is
  # encrypted too.
  struct PrivateImageFile
    include Kept

    # *file* as a private image; `not_an_image` when its type is not one.
    def self.of(file : File, *, alt : Punch::NonEmptyString? = nil, width : Int64? = nil, height : Int64? = nil) : self | Invalid
      build(key: file.key, filename: Punch::Secret.new(file.filename), size: file.size, content_type: file.content_type,
        scan_state: file.scan_state, delete_after: file.delete_after, width: width, height: height,
        alt: alt.try { |text| Punch::Secret.new(text) })
    end

    def self.check(value : self) : Invalid?
      Upload.check_image(value.content_type, value.width, value.height, value.alt.try(&.unwrap.value))
    end
  end

  alias PublicFile = File | ImageFile
  alias SecretFile = PrivateFile | PrivateImageFile
  alias AnyFile = PublicFile | SecretFile

  # Whether a file of *key*'s kind is scanned. A kind this binary does not
  # know was renamed, or removed: unknown is scanned as soon as the app
  # scans anything, so a rename does not switch a scan off.
  # :nodoc:
  def self.scanned_kind?(key : Key) : Bool
    rules = kinds[key.kind]?
    rules ? rules.scan : kinds.each_value.any?(&.scan)
  end

  # :nodoc:
  def self.check_image(content_type : String, width : Int64?, height : Int64?, alt : String?) : Invalid?
    return Invalid.new("not_an_image") unless content_type.starts_with?("image/")
    return Invalid.new("too_long", max: MAX_ALT_SIZE) if alt && alt.size > MAX_ALT_SIZE

    {width, height}.each do |side|
      return Invalid.new("out_of_range", min: 1, max: MAX_IMAGE_SIDE) if side && !(1..MAX_IMAGE_SIDE).includes?(side)
    end
    nil
  end

  # The longest side an image may say it has, in pixels.
  MAX_IMAGE_SIDE = 1_000_000_i64
  # The longest alt text, in characters.
  MAX_ALT_SIZE = 1_000
end

module Punch::Stored
  # A private file's stored form holds its name: `Stored.dump` is for
  # columns that are not encrypted, so it does not take one.
  def self.dump(value : Upload::SecretFile)
    {% raise "Punch::Upload::PrivateFile holds a secret, which Punch::Stored.dump would write in the clear. Map it as a group of columns (lib/punch/docs/uploads.md)." %}
  end
end
