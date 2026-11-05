require "json"

module Punch::Backup
  # The last restore check's result as `Verification` keeps it in
  # `verification.json` in the storage directory: enough for
  # `punch backup` and the metric `punch.backup.verification.age`.
  struct VerificationStatus
    include JSON::Serializable

    FILE = "verification.json"

    getter? passed : Bool
    getter started_at : Time
    getter finished_at : Time
    # When a check last passed: the last one, or one before it.
    getter last_passed_at : Time?
    getter problems : Array(String)
    # How many of each list of the reconciliation's dry run.
    getter reconciliation : Hash(String, Int64)?

    # The status kept in *storage*, or `nil` before the first check.
    def self.read(storage : String) : self?
      from_json(File.read(File.join(storage, FILE)))
    rescue File::Error | JSON::ParseException | JSON::SerializableError
      nil
    end
  end
end
