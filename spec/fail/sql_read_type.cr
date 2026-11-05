require "../../src/punch"

db = Punch::Database.memory
db.read { |reader| reader.query_all("SELECT created_at FROM invoices") { |row| row.read(Time) } }
