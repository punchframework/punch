require "../../src/punch"

MIGRATIONS = Punch::Migrations.embed("migrations_badly_named")
puts MIGRATIONS.size
