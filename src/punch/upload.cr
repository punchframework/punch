require "digest/sha256"
require "./upload/kind"
require "./upload/filename"
require "./upload/values"
require "./upload/scan_state"
require "./upload/composites.gen"
require "./upload/file"
require "./upload/settings"
require "./upload/storage"

module Punch
  # Direct uploads (`docs/uploads.md`): browsers send files straight to
  # S3-compatible storage, never through the app.
  #
  # 1. The app's Command grants an upload (`grant`): Punch picks the key,
  #    records it in `punch_uploads`, and signs a `PUT` URL for exactly the
  #    declared size and type, valid ten minutes.
  # 2. The client sends the file to the storage, then the ticket to
  #    `POST /_punch/uploads/check`. Punch reads what arrived (size, type,
  #    first bytes) and copies it to where checked files live. Nothing
  #    unchecked is ever served.
  # 3. The app's Command claims the checked upload with the ticket
  #    (`claim`) and keeps the `File` it gets.
  #
  # `Punch::Upload::Sweep` removes what was granted and never claimed, and
  # what the app discarded (`discard`).
  module Upload
    # Below this path Punch answers the check and, with local storage, the
    # signed `PUT` and `GET`.
    PREFIX     = "/_punch/uploads/"
    CHECK_PATH = "/_punch/uploads/check"
    LOCAL_PATH = "/_punch/uploads/local/"

    # How long after the grant the app may claim an upload; the sweep
    # removes it after that.
    class_property claim_window : Time::Span = 1.hour

    # How many uploads one owner may have granted and not claimed at once.
    class_property pending_limit : Int32 = 20

    @@storage : Storage?
    @@settings_problems = [] of String
    @@configured = false

    # Sets up the storage from the app's settings; done at boot by the
    # credentials (*field* is where they are declared). Problems are kept
    # for the boot to report.
    def self.configure(settings : Settings, field : String = "uploads") : Nil
      @@configured = true
      @@settings_problems = settings.problems(field)
      @@storage = nil
      return unless @@settings_problems.empty?

      prefix = settings.prefix || ""
      @@storage = case settings.storage
                  in .s3?    then S3Storage.new(settings.s3_bucket, settings.s3_credentials, prefix)
                  in .local? then LocalStorage.new(prefix: prefix)
                  end
    end

    # What is wrong with the settings for *environment*, and an app with
    # kinds of upload but no settings.
    # :nodoc:
    def self.problems(environment : String, field : String = "uploads") : Array(String)
      problems = @@settings_problems.dup
      if used? && !@@configured
        problems << "the app declares kinds of upload, but its credentials have no `getter uploads : Punch::Upload::Settings` (lib/punch/docs/uploads.md)"
      end
      if @@storage.is_a?(LocalStorage) && !environment.in?("development", "test")
        problems << "#{field}.storage is local in #{environment}: files would pass through the app and stay on its disk; set s3"
      end
      problems
    end

    # Uses *storage* in this process; specs do this.
    def self.storage=(storage : Storage?) : Storage?
      @@storage = storage
    end

    # The storage the settings name.
    def self.storage : Storage
      @@storage || raise Credentials::NotLoaded.new("No upload storage has been set up. Declare `getter uploads : Punch::Upload::Settings` in the app's credentials (lib/punch/docs/uploads.md); specs call Punch::Spec.credentials.")
    end

    # The storage, if one is set up.
    # :nodoc:
    def self.storage? : Storage?
      @@storage
    end

    # Grants an upload of *kind*: a file of *size* bytes and
    # *content_type*, for *owner*, whom the claim must name again (the
    # user's ID, or the session's for anonymous uploads). Refused at
    # `size` or `content_type` when the kind's rules forbid them, and as a
    # whole while *owner* has `pending_limit` uploads granted and not yet
    # claimed. *filename* is the name the client gave the file, made to
    # fit its type (`Filename#for`); without one the file gets a plain
    # name. Call it in the Command that hands out uploads, which authorizes
    # and rate-limits them.
    def self.grant(db : Writer, kind : K.class, *, size : Int64 | Int32, content_type : String, owner : String,
                   filename : Filename? = nil, now : Time = Time.utc) : Grant | Rejection forall K
      rules = K.upload_rules
      errors = Rejection::Collector.new
      if size < 1
        errors.add("size", Invalid.new("out_of_range", min: 1, max: rules.max_size))
      elsif size > rules.max_size
        errors.add("size", Invalid.new("too_large", max: rules.max_size))
      end
      errors.add("content_type", Invalid.new("unsupported_type", types: rules.types.join(", "))) unless rules.types.includes?(content_type)
      errors.result { nil }.try { |rejection| return rejection }

      waiting = db.query_one?("SELECT count(*) FROM punch_uploads WHERE owner = ? AND state IN ('granted', 'checking', 'checked') AND expires_at > ?",
        owner, now.to_unix_ms, name: "Punch::Upload.grant.waiting", &.read(Int64)) || 0_i64
      return Rejection.new(Rejection::Path.new, Invalid.new("too_many_uploads", max: pending_limit)) if waiting >= pending_limit

      storage = self.storage
      ticket = Ticket.generate
      id = Alphabet.random(16)
      url, headers = storage.presign_put(storage.pending_key(id), size.to_i64, content_type, now)
      name = filename.try(&.for(content_type)) || Filename.default(content_type)
      db.exec("INSERT INTO punch_uploads (id, ticket_digest, kind, owner, size, content_type, filename, state, created_at, expires_at) " \
              "VALUES (?, ?, ?, ?, ?, ?, ?, 'granted', ?, ?)",
        id, ticket.digest, rules.name, owner, size.to_i64, content_type, name.value, now.to_unix_ms, (now + claim_window).to_unix_ms,
        name: "Punch::Upload.grant")
      Grant.new(ticket, url, headers, now + Storage::PUT_EXPIRY)
    end

    # What the check answers for a file that is what was granted.
    struct Checked
      include JSON::Serializable

      @[JSON::Field(ignore: true)]
      getter kind : String
      getter size : Int64
      getter content_type : String

      def initialize(@kind : String, @size : Int64, @content_type : String)
      end
    end

    # Why the check refused: the status and code it answers with.
    record Refused, status : ::HTTP::Status, code : String

    # How long one check holds an upload (state `checking`) before another
    # may take it over, as after a crash. Longer than a check can take: its
    # three storage requests time out after 10 s to connect and 10 s to
    # read each, and a check past half of this gives up before it copies.
    CHECK_LEASE = 3.minutes

    # Reads what arrived for *ticket*, and copies it to the checked files
    # when it is what was granted: the size, the type, and the first bytes
    # (`TYPES`). Refused 404 `upload_not_found` (no such ticket, claimed,
    # or expired), 409 `upload_incomplete` (nothing arrived yet), 409
    # `upload_checking` (another check of it runs), 422 `upload_mismatch`
    # (another size, type, or content; what arrived is deleted, and the
    # client may send the file again while its URL lasts), 502
    # `upload_storage_unavailable`. One check runs at a time per upload:
    # it takes the upload (`granted` to `checking`) before it asks the
    # storage, so a file sent again during a check, or after it, never
    # reaches the checked copy. Outside any transaction: the storage may
    # take a while, and the writer is held only for the state changes.
    # Checking a checked upload again answers the same.
    def self.check(database : Database, ticket : Ticket, now : Time = Time.utc) : Checked | Refused
      found = database.read do |db|
        db.query_one?("SELECT id, kind, size, content_type, state FROM punch_uploads " \
                      "WHERE ticket_digest = ? AND state IN ('granted', 'checking', 'checked') AND expires_at > ?",
          ticket.digest, now.to_unix_ms, name: "Punch::Upload.check.find") do |row|
          {row.read(String), row.read(String), row.read(Int64), row.read(String), row.read(String)}
        end
      end
      return Refused.new(:not_found, "upload_not_found") unless found

      id, kind, size, content_type, state = found
      checked = Checked.new(kind, size, content_type)
      return checked if state == "checked"
      return checked_or_running(database, id, checked) unless take(database, id, now)

      begin
        run_check(database, id, kind, size, content_type, now) || checked
      rescue ex : S3::Error | IO::Error | Socket::Error | OpenSSL::Error
        Trace.event.record_exception(ex)
        release(database, id)
        Refused.new(:bad_gateway, "upload_storage_unavailable")
      end
    end

    # Takes the upload for this check: whether no other check holds it.
    private def self.take(database : Database, id : String, now : Time) : Bool
      database.write do |db|
        db.exec("UPDATE punch_uploads SET state = 'checking', checking_since = ? WHERE id = ? AND expires_at > ? " \
                "AND (state = 'granted' OR (state = 'checking' AND checking_since <= ?))",
          now.to_unix_ms, id, now.to_unix_ms, (now - CHECK_LEASE).to_unix_ms, name: "Punch::Upload.check.take").changes > 0
      end
    end

    # Gives the upload back after a check that did not end in a copy.
    private def self.release(database : Database, id : String) : Nil
      database.write do |db|
        db.exec("UPDATE punch_uploads SET state = 'granted', checking_since = NULL WHERE id = ? AND state = 'checking'", id,
          name: "Punch::Upload.check.release")
      end
    end

    private def self.checked_or_running(database : Database, id : String, checked : Checked) : Checked | Refused
      state = database.read do |db|
        db.query_one?("SELECT state FROM punch_uploads WHERE id = ?", id, name: "Punch::Upload.check.state", &.read(String))
      end
      case state
      when "checked", "claimed" then checked
      when "checking"           then Refused.new(:conflict, "upload_checking")
      else                           Refused.new(:not_found, "upload_not_found")
      end
    end

    # The storage's part of a check, holding the upload; `nil` when the
    # file is checked and copied.
    private def self.run_check(database : Database, id : String, kind : String, size : Int64, content_type : String, started : Time) : Refused?
      storage = self.storage
      pending = storage.pending_key(id)
      final = storage.file_key(Key.of(kind, id))
      unless head = storage.head(pending)
        release(database, id)
        return Refused.new(:conflict, "upload_incomplete")
      end
      unless head.size == size && head.content_type.try(&.split(';').first.strip.downcase) == content_type &&
             TYPES[content_type].check.call(storage.read_start(pending, SNIFF_BYTES, head.etag))
        storage.delete(pending)
        release(database, id)
        return Refused.new(:unprocessable_entity, "upload_mismatch")
      end
      # Past half the lease, another check may take the upload soon: no copy.
      raise IO::TimeoutError.new("the check took longer than half its lease") if Time.utc - started > CHECK_LEASE / 2

      storage.copy(pending, final, etag: head.etag, content_type: content_type, disposition: Storage.disposition(content_type))
      changed = database.write do |db|
        db.exec("UPDATE punch_uploads SET state = 'checked', checking_since = NULL WHERE id = ? AND state = 'checking'",
          id, name: "Punch::Upload.check").changes
      end
      storage.delete(pending)
      return if changed > 0

      # Swept while the storage was asked: no copy left behind.
      storage.delete(final)
      Refused.new(:not_found, "upload_not_found")
    end

    # Claims the checked upload *ticket* names for the app: it must be of
    # *kind*, granted to *owner*, checked, and within the claim window.
    # From then on the file is the app's: it keeps the `File`, and the
    # sweep leaves the file alone until the app discards it. A ticket
    # claims once. Refused with `upload_not_found`, or `upload_not_checked`
    # while the file has not been checked; return it at the input's field
    # (`Punch::Rejection.new(Punch::Rejection::Path{"scan"}, invalid)`). The
    # file name is the app's to keep: `punch_uploads` forgets it here, since
    # a name can be personal data.
    def self.claim(db : Writer, ticket : Ticket, kind : K.class, *, owner : String, now : Time = Time.utc) : File | Invalid forall K
      rules = K.upload_rules
      found = db.query_one?("SELECT id, state, size, content_type, filename FROM punch_uploads " \
                            "WHERE ticket_digest = ? AND kind = ? AND owner = ? AND state IN ('granted', 'checking', 'checked') AND expires_at > ?",
        ticket.digest, rules.name, owner, now.to_unix_ms, name: "Punch::Upload.claim.find") do |row|
        {row.read(String), row.read(String), row.read(Int64), row.read(String), row.read(String?)}
      end
      return Invalid.new("upload_not_found") unless found

      id, state, size, content_type, stored = found
      return Invalid.new("upload_not_checked") unless state == "checked"

      db.exec("UPDATE punch_uploads SET state = 'claimed', claimed_at = ?, expires_at = NULL, filename = NULL WHERE id = ? AND state = 'checked'",
        now.to_unix_ms, id, name: "Punch::Upload.claim")
      name = stored.try { |raw| Filename.parse(raw).as?(Filename) } || Filename.default(content_type)
      File.build(key: Key.of(rules.name, id), filename: name, size: size, content_type: content_type,
        scan_state: rules.scan ? ScanState::PENDING : nil).as(File)
    end

    # Gives a claimed file of *owner* up: the sweep deletes it from the
    # storage soon after the transaction commits. Whether *key* was a
    # claimed file of *owner*'s; another owner's key changes nothing.
    def self.discard(db : Writer, key : Key, *, owner : String, now : Time = Time.utc) : Bool
      db.exec("UPDATE punch_uploads SET state = 'discarded', expires_at = ? WHERE id = ? AND kind = ? AND owner = ? AND state = 'claimed'",
        now.to_unix_ms, key.id, key.kind, owner, name: "Punch::Upload.discard").changes > 0
    end

    # Gives up a file whoever's it is: the sweep deletes it from the storage
    # soon after the transaction commits, which is the end of every URL
    # signed for it. For the app's own jobs, such as one that quarantines a
    # file; a Command acting for a user takes `discard`, which checks the
    # owner. Whether *key* was a claimed file.
    def self.purge(db : Writer, key : Key, *, now : Time = Time.utc) : Bool
      db.exec("UPDATE punch_uploads SET state = 'discarded', expires_at = ? WHERE id = ? AND kind = ? AND state = 'claimed'",
        now.to_unix_ms, key.id, key.kind, name: "Punch::Upload.purge").changes > 0
    end

    # Gives up *file* whoever's it is, as for its key.
    def self.purge(db : Writer, file : AnyFile, *, now : Time = Time.utc) : Bool
      purge(db, file.key, now: now)
    end

    # Gives *file* up, as for its key.
    def self.discard(db : Writer, file : AnyFile, *, owner : String, now : Time = Time.utc) : Bool
      discard(db, file.key, owner: owner, now: now)
    end

    # A URL that fetches the checked file *key* for *expires*, from the
    # storage: put it into the page of whoever may see the file. With
    # *download*, the browser saves the file under that name. Signing is
    # local; nothing is asked of the storage or the database, so check
    # that the viewer may see the file first. A bare key says nothing of a
    # scan, so a key of a scanned kind raises `NotServable`; a job that reads
    # a file to scan it passes `unscanned: true`.
    def self.url(key : Key, *, expires : Time::Span = 1.hour, download : String? = nil, unscanned : Bool = false, now : Time = Time.utc) : String
      raise NotServable.new(key) if !unscanned && scanned_kind?(key)

      storage = self.storage
      storage.presign_get(storage.file_key(key), now, expires, download)
    end

    # A URL that fetches *file*: shown where its type may be, or with
    # *download*, saved. `download: true` saves it under its name; a
    # `Filename` under that one, fitted to the file's type. A `PrivateFile`
    # with `download: true` is saved under a plain name such as `file.pdf`,
    # since a name in a URL is no longer private. A file of a scanned kind
    # that is not `clean` raises `NotServable`: `url?` answers `nil` instead.
    # Such a URL lasts at most `SCANNED_EXPIRY`, since a later quarantine
    # does not reach it.
    def self.url(file : AnyFile, *, expires : Time::Span = 1.hour, download : Bool | Filename = false, now : Time = Time.utc) : String
      raise NotServable.new(file.key, file.scan_state) unless file.servable?

      expires = {expires, SCANNED_EXPIRY}.min if scanned_kind?(file.key)
      url(file.key, expires: expires, download: download_name(file, download).try(&.value), unscanned: true, now: now)
    end

    # `url`, or `nil` for a file that is not servable: for pages and answers,
    # which should show that a file is waiting rather than fail.
    def self.url?(file : AnyFile, *, expires : Time::Span = 1.hour, download : Bool | Filename = false, now : Time = Time.utc) : String?
      url(file, expires: expires, download: download, now: now) if file.servable?
    end

    # The longest a URL for a file of a scanned kind lasts.
    SCANNED_EXPIRY = 1.hour

    private def self.download_name(file : AnyFile, download : Bool | Filename) : Filename?
      case download
      in Filename then download.for(file.content_type)
      in Bool
        return unless download

        file.is_a?(PublicFile) ? file.filename.for(file.content_type) : Filename.default(file.content_type)
      end
    end

    # `url` as a link or image source for a view:
    # `v.img src: Punch::Upload.href(receipt.scan), alt: "Scan"`.
    def self.href(key : Key, *, expires : Time::Span = 1.hour, download : String? = nil, unscanned : Bool = false, now : Time = Time.utc) : Href
      Href.new(url(key, expires: expires, download: download, unscanned: unscanned, now: now), nil)
    end

    # `url` of *file* as a link or image source for a view.
    def self.href(file : AnyFile, *, expires : Time::Span = 1.hour, download : Bool | Filename = false, now : Time = Time.utc) : Href
      Href.new(url(file, expires: expires, download: download, now: now), nil)
    end

    # `href`, or `nil` for a file that is not servable.
    def self.href?(file : AnyFile, *, expires : Time::Span = 1.hour, download : Bool | Filename = false, now : Time = Time.utc) : Href?
      href(file, expires: expires, download: download, now: now) if file.servable?
    end

    # The origin pages need for uploads and files beyond their own, for
    # the Content-Security-Policy; `nil` when there is none.
    # :nodoc:
    def self.origin : String?
      @@storage.try(&.csp_source)
    end

    @@policy : {String, String, String}?

    # *policy*, the default Content-Security-Policy, allowing the bucket
    # (its origin, or with path-style URLs its path below a shared host) to
    # receive files (`connect-src`) and to show them (`img-src`,
    # `media-src`); unchanged without a bucket.
    # :nodoc:
    def self.content_security_policy(policy : String) : String
      origin = self.origin || return policy
      if (cached = @@policy) && cached[0].same?(policy) && cached[1] == origin
        return cached[2]
      end

      sources = "'self' #{origin}"
      widened = policy.sub("default-src 'self';", "default-src 'self'; connect-src #{sources}; img-src #{sources}; media-src #{sources};")
      @@policy = {policy, origin, widened}
      widened
    end

    # What `configure` found wrong with the settings.
    # :nodoc:
    def self.settings_problems : Array(String)
      @@settings_problems
    end

    # The table lives in the app's migrations, like the outbox; its columns
    # are Punch's, checked when the server starts.
    COLUMNS = {
      "id" => "TEXT", "ticket_digest" => "BLOB", "kind" => "TEXT", "owner" => "TEXT", "size" => "INTEGER",
      "content_type" => "TEXT", "filename" => "TEXT", "state" => "TEXT", "created_at" => "INTEGER", "expires_at" => "INTEGER",
      "claimed_at" => "INTEGER", "checking_since" => "INTEGER",
    }

    # The table as a migration (`punch db:migration --punch uploads`).
    def self.sql : String
      <<-SQL
        -- Direct uploads (lib/punch/docs/uploads.md): each one granted, being checked, checked,
        -- claimed by the app, or discarded. The columns are Punch's.
        CREATE TABLE punch_uploads (
          id            TEXT    NOT NULL PRIMARY KEY,
          ticket_digest BLOB    NOT NULL UNIQUE,
          kind          TEXT    NOT NULL,
          owner         TEXT    NOT NULL,
          size          INTEGER NOT NULL,
          content_type  TEXT    NOT NULL,
          filename      TEXT,
          state         TEXT    NOT NULL CHECK (state IN ('granted', 'checking', 'checked', 'claimed', 'discarded')),
          created_at    INTEGER NOT NULL,
          expires_at    INTEGER,
          claimed_at    INTEGER,
          checking_since INTEGER
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX punch_uploads_owner ON punch_uploads (owner, state, expires_at);
        CREATE INDEX punch_uploads_sweep ON punch_uploads (expires_at) WHERE expires_at IS NOT NULL;

        SQL
    end

    # What is missing or of another type, one line each; empty when the
    # table is as Punch needs it.
    def self.table_problems(database : Database) : Array(String)
      found = database.read do |db|
        db.query_all("SELECT name, type FROM pragma_table_info('punch_uploads')", name: "Punch::Upload.columns") do |row|
          {row.read(String), row.read(String).upcase}
        end.to_h
      end
      return ["table punch_uploads is missing; add it with `punch db:migration --punch uploads` (lib/punch/docs/uploads.md)"] if found.empty?

      COLUMNS.compact_map do |column, type|
        if actual = found[column]?
          "punch_uploads.#{column} is #{actual}, Punch needs #{type}" unless actual == type
        else
          "punch_uploads.#{column} is missing (lib/punch/docs/uploads.md)"
        end
      end
    end
  end
end

require "./upload/endpoint"
require "./upload/sweep"
