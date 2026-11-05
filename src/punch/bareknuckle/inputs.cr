require "digest/sha256"

module Punch::Bareknuckle
  # Which work a warm compiler would need for a round, by where its edits
  # land; ordered from cheapest.
  enum Tier
    # Nothing the build reads changed.
    None
    # Method bodies only: re-type and regenerate those methods, relink.
    Fast
    # Method signatures changed where no Punch macro reads them: re-type
    # the callers until types settle.
    Propagation
    # Anything a whole-program macro reads, or a file the compile embeds:
    # today's full build.
    Full
  end

  # One file that differs from the last build, with its kind (the require
  # file's kinds under `app/`, otherwise what the file is to a build) and
  # what a warm compiler would have to do about it.
  record Edit, path : String, kind : String, change : Change, tier : Tier do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "path", path
        json.field "kind", kind
        json.field "change", change.to_s.underscore
        json.field "tier", tier.to_s.underscore
      end
    end
  end

  # What the build of a round read: the contents of every Crystal file and
  # a digest of every other file, by path.
  struct Inputs
    # Kinds of `app/` files whose methods Punch's macros read: by name
    # (`call`, `live`, `perform`, `view`, `initialize`, setters), by
    # parameter types, or by visibility. A signature change there may
    # change a macro's output, so it is a full build.
    MACRO_READ = %w[types events shared operations components pages roles setup outline]

    # Files that are not Crystal whose changes reach the build only
    # through a generated Crystal file, which is compared itself.
    GENERATED_FROM = %w[locale queries schema]

    # Files a `punch dev` build reads while it runs (`-Dpunch_dev`), so a
    # change of their contents needs no build. A new or removed one does:
    # the compile-time list of assets changes.
    READ_AT_RUN_TIME = %w[asset]

    # Kinds whose string literals only the running app reads
    # (`Change::Data`).
    DATA = %w[translations]

    getter sources : Hash(String, String)
    getter digests : Hash(String, String)

    def initialize(@sources = {} of String => String, @digests = {} of String => String)
    end

    # The inputs among *paths*, read now.
    def self.capture(paths : Enumerable(String)) : Inputs
      inputs = new
      paths.each do |path|
        content = File.read(path) rescue next # removed since listed
        if path.ends_with?(".cr")
          inputs.sources[path] = content
        else
          inputs.digests[path] = Digest::SHA256.hexdigest(content)
        end
      end
      inputs
    end

    # Every file that differs between *before* and this, sorted by path.
    def edits(before : Inputs) : Array(Edit)
      edits = [] of Edit
      (sources.keys | before.sources.keys).each do |path|
        old = before.sources[path]?
        new = sources[path]?
        next if old == new

        change = if old.nil?
                   Change::Added
                 elsif new.nil?
                   Change::Removed
                 else
                   Fingerprint.change(old, new, data: Inputs.kind(path).in?(DATA))
                 end
        edits << edit(path, change)
      end
      (digests.keys | before.digests.keys).each do |path|
        old = before.digests[path]?
        new = digests[path]?
        next if old == new

        edits << edit(path, old.nil? ? Change::Added : new.nil? ? Change::Removed : Change::Content)
      end
      edits.sort_by!(&.path)
    end

    # The most expensive tier among *edits*.
    def self.tier(edits : Array(Edit)) : Tier
      edits.max_of?(&.tier) || Tier::None
    end

    private def edit(path : String, change : Change) : Edit
      kind = Inputs.kind(path)
      Edit.new(path, kind, change, Inputs.tier(kind, change))
    end

    def self.tier(kind : String, change : Change) : Tier
      case change
      in .none?                          then Tier::None
      in .body?, .data?                  then Tier::Fast
      in .signature?                     then MACRO_READ.includes?(kind) ? Tier::Full : Tier::Propagation
      in .structure?, .added?, .removed? then GENERATED_FROM.includes?(kind) ? Tier::None : Tier::Full
      in .content?                       then GENERATED_FROM.includes?(kind) || READ_AT_RUN_TIME.includes?(kind) ? Tier::None : Tier::Full
      end
    end

    # What *path* is to a build: a file kind of `app/`
    # (`lib/punch/docs/structure.md`), `library` for other Crystal files,
    # or what a non-Crystal file feeds.
    def self.kind(path : String) : String
      return crystal_kind(path) if path.ends_with?(".cr")

      case path
      when .starts_with?("config/locales/")     then "locale"
      when .starts_with?("config/credentials/") then "credentials"
      when .starts_with?("db/migrations/")      then "migration"
      when "db/schema.sql"                      then "schema"
      when .ends_with?(".sql")                  then "queries"
      when .includes?("/assets/")               then "asset"
      when "shard.yml", "shard.lock"            then "shard"
      when "openapi.json"                       then "openapi"
      else                                           "other"
      end
    end

    # The kind of a Crystal file: its kind under `app/` (`unknown` for one
    # that fits none, or is gone), `library` elsewhere.
    private def self.crystal_kind(path : String) : String
      return "library" unless path.starts_with?("#{RequiresGen::DIRECTORY}/")
      return "requires" if path == RequiresGen::OUTPUT
      return "unknown" unless File.exists?(path)

      kind = RequiresGen.kind(path.lchop("#{RequiresGen::DIRECTORY}/"), RequiresGen::DIRECTORY, [] of QueryGen::Error)
      kind ? kind.to_s.underscore : "unknown"
    end
  end
end
