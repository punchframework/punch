module Punch::Upload
  # Defined only in an app that declares kinds of upload, so other apps
  # have no job type more in their payload lock.
  macro finished
    {% unless Punch::Upload::Kind.includers.reject { |kind| kind.abstract? || kind.module? }.empty? %}
      {% verbatim do %}
  # Removes, every ten minutes, the uploads granted and not claimed within
  # the claim window, and the files the app discarded: first from the
  # storage, then from `punch_uploads`. It also removes, once an upload's
  # `PUT` URL has expired, a pending file of another size than was granted,
  # which a storage that does not check the signed `Content-Length` lets in
  # (`trim`). A bucket's lifecycle rule on `pending/` (delete after a day)
  # catches what a process never got to. An expired upload's file name goes
  # first, in the database, whether or not the storage can be reached.
  @[Punch::Job::Recurring(every: 10.minutes)]
  struct Sweep
    include Punch::Job

    # Uploads removed per batch; a run takes at most `BATCHES` of them.
    BATCH   = 100
    BATCHES =  20

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      now = Time.utc
      Sweep.forget_names(job, now)
      removed = Sweep.run(job, now)
      trimmed = Sweep.trim(job, now)
      if Trace.event.recording?
        Trace.event.set("punch.uploads.swept", removed)
        Trace.event.set("punch.uploads.trimmed", trimmed)
      end
      nil
    end

    # Clears the file names of uploads past their claim window: a name can
    # be personal data, and nothing reads it after that. Only the database
    # is asked, so a storage that is down keeps no name. How many.
    def self.forget_names(database, now : Time = Time.utc) : Int64
      database.write do |db|
        db.exec("UPDATE punch_uploads SET filename = NULL WHERE filename IS NOT NULL AND expires_at IS NOT NULL AND expires_at <= ?",
          now.to_unix_ms, name: "Punch::Upload::Sweep.forget_names").changes
      end
    end

    # Removes what is due by *now*, reading and writing through *database*
    # (a `Database` or a job's context); how many uploads.
    def self.run(database, now : Time = Time.utc) : Int32
      storage = Upload.storage
      removed = 0
      BATCHES.times do
        due = database.read do |db|
          db.query_all("SELECT id, kind, state FROM punch_uploads WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at LIMIT ?",
            now.to_unix_ms, BATCH, name: "Punch::Upload::Sweep.due") do |row|
            {row.read(String), row.read(String), row.read(String)}
          end
        end
        break if due.empty?

        gone = due.compact_map { |(id, kind, state)| remove(storage, id, kind, state) }
        database.write do |db|
          gone.each do |id|
            db.exec("DELETE FROM punch_uploads WHERE id = ? AND expires_at IS NOT NULL AND expires_at <= ?", id, now.to_unix_ms,
              name: "Punch::Upload::Sweep.delete")
          end
        end
        removed += gone.size
        break if due.size < BATCH || gone.size < due.size
      end
      removed
    end

    # Deletes the pending files of unchecked uploads that are not the size
    # granted, once their `PUT` URLs have expired: nothing can claim such a
    # file, and it would otherwise fill the bucket until the claim window
    # ends. A file of the granted size stays, however late it arrived: the
    # storage checks a URL's expiry when a `PUT` starts, so a slow upload
    # finishes after it. How many files; asks the storage once per upload.
    def self.trim(database, now : Time = Time.utc) : Int32
      storage = Upload.storage
      unchecked = database.read do |db|
        db.query_all("SELECT id, size FROM punch_uploads WHERE state = 'granted' AND created_at <= ? AND expires_at > ? ORDER BY created_at LIMIT ?",
          (now - Storage::PUT_EXPIRY).to_unix_ms, now.to_unix_ms, BATCH * BATCHES, name: "Punch::Upload::Sweep.unchecked") do |row|
          {row.read(String), row.read(Int64)}
        end
      end
      unchecked.count do |(id, size)|
        pending = storage.pending_key(id)
        found = storage.head(pending)
        next false if found.nil? || found.size == size

        storage.delete(pending)
        true
      rescue ex : S3::Error | IO::Error | Socket::Error | OpenSSL::Error
        Trace.event.record_exception(ex)
        false
      end
    end

    # Deletes the objects of one upload; its ID once they are gone, `nil`
    # when the storage could not be reached.
    private def self.remove(storage : Storage, id : String, kind : String, state : String) : String?
      storage.delete(storage.pending_key(id)) unless state == "discarded"
      # Also for a granted one: a check may have copied it as it expired.
      storage.delete(storage.file_key(Key.of(kind, id)))
      id
    rescue ex : S3::Error | IO::Error | Socket::Error | OpenSSL::Error
      Trace.event.record_exception(ex)
      nil
    end
  end
      {% end %}
    {% end %}
  end
end
