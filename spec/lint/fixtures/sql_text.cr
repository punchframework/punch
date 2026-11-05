# Fixture for Punch/SQLText: SQL text from values, and what is accepted.
module Shop
  COLUMNS = "id, name"
  TABLES  = {"CREATE TABLE a (id INTEGER)", "CREATE TABLE b (id INTEGER)"}
  PRAGMAS = {journal: "PRAGMA journal_mode", sync: {"PRAGMA synchronous", 1}}
  ADDED   = ["CREATE TABLE c (id INTEGER)"]
  SCRIPT  = <<-SQL
    CREATE TABLE d (id INTEGER);
    CREATE TABLE e (id INTEGER);
    SQL

  macro run_for(value)
    db.exec("DELETE FROM t WHERE id = #{{{value}}}") # expect
    db.exec("DELETE FROM {{value.id}}")
  end

  def self.reported(db : Punch::Writer, name : String, table : String, order : String) : Nil
    db.query_all("SELECT id FROM customers WHERE name = '#{name}'") { |row| row.read(Int64) } # expect
    db.exec("DELETE FROM " + table)                                                           # expect
    db.query_one?("SELECT %s FROM t" % order) { |row| row.read(Int64) }                       # expect
    db.query_each(<<-SQL) { |row| row.read(Int64) }                                           # expect
      SELECT #{COLUMNS} FROM customers ORDER BY #{order}
      SQL
    sql = "SELECT id FROM t ORDER BY " + order
    db.query_all(sql) { |row| row.read(Int64) } # expect
    built = String.build do |io|
      io << "SELECT id FROM t WHERE name = '" << name << "'"
    end
    db.query_all(built) { |row| row.read(Int64) } # expect
    leaked = String.build do |io|
      io << "SELECT id FROM t"
      name.to_s(io)
    end
    db.query_all(leaked) { |row| row.read(Int64) } # expect
    first, second = "SELECT 1", "SELECT 2"
    db.exec(first)                       # expect
    [name].each { |text| db.exec(text) } # expect
    db.exec(@sql)                        # expect
    db.exec(name)                        # expect
    db.exec(sql: "DELETE FROM #{table}") # expect
    ADDED.each { |sql| db.exec(sql) }    # expect
    Helper.exec(db, name)                # expect
    {% begin %}
      db.exec("DELETE FROM #{table}") # expect
    {% end %}
    {% if flag?(:release) %}
      db.exec(name) # expect
    {% else %}
      db.query_all("SELECT 1 WHERE x = '#{name}'") { |row| row.read(Int64) } # expect
    {% end %}
  end

  def self.accepted(db : Punch::Writer, name : String, desc : Bool) : Nil
    db.query_all("SELECT id FROM customers WHERE name = ?", name) { |row| row.read(Int64) }
    db.query_all("SELECT #{COLUMNS} FROM customers") { |row| row.read(Int64) }
    db.query_one?(Queries::Find::SQL, name) { |row| row.read(Int64) }
    db.exec(COLUMNS + " " + (desc ? "DESC" : "ASC"))
    TABLES.each { |sql| db.exec(sql) }
    sql = desc ? "SELECT id FROM t ORDER BY id DESC" : "SELECT id FROM t ORDER BY id"
    db.query_all(sql) { |row| row.read(Int64) }
    args = [] of Punch::Database::Value
    assembled = String.build do |io|
      io << Queries::Page::SQL_1 << '\n'
      args << name
      io << (desc ? Queries::Page::ORDER_DESC : Queries::Page::ORDER) << '\n' if desc
      io << "LIMIT ?"
    end
    db.query_all(assembled, args: args) { |row| row.read(Int64) }
    PRAGMAS.each { |_, sql| db.exec(sql) }
    SCRIPT.each_line { |sql| db.exec(sql) }
    db.exec(sql: "DELETE FROM t")
    {% for table in %w[a b] %}
      db.exec("DELETE FROM {{table.id}}")
    {% end %}
    Process.exec(name)
    LibC.exec(name)
    URI.parse(name).query
  end

  # Forwarding inside the database layer: a method named like the ones the
  # rule checks may pass its own parameter on.
  def query_all(sql : String, *args)
    connection.query(sql, args)
  end

  def run(sql : String)
    connection.exec(sql) # expect
  end

  module Helper
    # A forwarder named like a database method takes SQL first, so its
    # callers are checked.
    def self.exec(db : Punch::Writer, sql : String)
      db.exec(sql) # expect
    end

    def self.query_all(sql : String, db : Punch::Reader)
      db.query_all(sql) { |row| row.read(Int64) }
    end

    def self.exec_on(db : Punch::Writer, text : String)
      db.exec(text) # expect
    end

    def self.prepared(db : Punch::Writer, text : String)
      db.exec(text) # expect
    end
  end
end
