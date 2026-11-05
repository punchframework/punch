require "../../src/punch"

db = Punch::Database.memory
email = Punch::Email.parse("ann@example.org").as(Punch::Email)
db.write { |writer| writer.exec("INSERT INTO customers (email) VALUES (?)", email) }
