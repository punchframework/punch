# Checked by spec/lint/rules_spec.cr: every line marked `# expect`
# must be reported by Punch/DriverTypes.
require "db"                 # expect
require "sqlite3/connection" # expect
require "json"

module App
  def self.leak(db : DB::Database) # expect
    db.exec("DELETE FROM invoices")
    ::SQLite3::Connection                # expect
    LibSQLite3.reset(Pointer(Void).null) # expect
    Punch::Reader
  end
end
