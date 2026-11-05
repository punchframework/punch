module AuthSchema
  SQL = <<-SQL + Punch::Auth::Schema.sql
    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;

    SQL

  # A memory database with a users table and Punch's auth tables, and
  # users 1 and 2.
  def self.database(& : Punch::Database ->) : Nil
    Punch::Spec.database do |database|
      Punch::Migrations::Schema.load(database, SQL, "auth")
      database.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')"))
      yield database
    end
  end

  # Runs the block with the auth schema as `Punch::Spec.db`'s, users 1
  # and 2 inserted; *extra* adds more tables.
  def self.with_spec_db(extra : String = "", &)
    path = File.tempname("auth-spec", ".sql")
    File.write(path, SQL + extra)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      Punch::Spec.db.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace')"))
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end
end
