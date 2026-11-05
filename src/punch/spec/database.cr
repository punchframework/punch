module Punch::Spec
  # The schema each example's database starts from: the app's
  # `db/schema.sql` when it exists, relative to where specs run. Set it in
  # `spec/spec_helper.cr` for another file, or to `nil` for an empty
  # database.
  class_property schema : String? = File.exists?(Migrations::SCHEMA) ? Migrations::SCHEMA : nil

  @@db : Database?
  @@db_lock = Mutex.new
  @@schema_sql : {String, String}?

  # This example's database: in memory, opened with the schema loaded on
  # first use, and closed after the example. Every example starts from the
  # same state, without rollback tricks, so code under test may commit,
  # fail, and run its own transactions.
  #
  # ```
  # it "sends a draft" do
  #   id = Punch::Spec.db.write { |db| Invoices::Table.insert(db, draft) }
  #   ...
  # end
  # ```
  def self.db : Database
    @@db_lock.synchronize do
      @@db ||= begin
        database = Database.memory(name: "spec", config: Database::Config.new(readers: 2))
        if path = schema
          sql = schema_sql(path)
          begin
            Migrations::Schema.load(database, sql, path)
            Roles.sync(database) if Roles.used? && Roles::Schema.present?(database)
          rescue ex
            database.close
            raise ex
          end
        end
        database
      end
    end
  end

  # Closes this example's database; runs after every example.
  def self.close_db : Nil
    database = @@db_lock.synchronize { @@db.tap { @@db = nil } }
    database.try(&.close)
  end

  # The schema file, read once per run.
  private def self.schema_sql(path : String) : String
    cached = @@schema_sql
    return cached[1] if cached && cached[0] == path

    File.read(path).tap { |sql| @@schema_sql = {path, sql} }
  end
end

Spec.after_each { Punch::Spec.close_db }
