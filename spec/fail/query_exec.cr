require "../../src/punch"

db = Punch::Database.memory
db.read { |reader| reader.exec("DELETE FROM invoices") }
