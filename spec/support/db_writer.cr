# Started by spec/database/database_spec.cr: writes N rows to the database at
# the given path through its own writer, while the spec writes to it too.
require "../../src/punch"

path, count = ARGV[0], ARGV[1].to_i
db = Punch::Database.open(path, config: Punch::Database::Config.new(readers: 1))
count.times { |i| db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (?)", "child-#{i}") } }
db.close
