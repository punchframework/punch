# Development data: `punch db:seed` runs this against the development
# database (lib/punch/docs/tooling.md). It signs up through the app's own
# Command, so seeded users pass the same rules as real ones, and skips what
# is there already, so running it again is safe.
require "../src/invoicing"
require "punch/seeds"

# Development only: never use this address anywhere else. The password is
# made at random for each new database and kept beside it in the storage
# directory, which is never committed, so no two apps share it.
ADMIN_EMAIL   = "admin@example.test"
PASSWORD_FILE = File.join(ENV["PUNCH_STORAGE"]?.presence || "storage", "seed-password")

Punch::Seeds.run do |seed|
  email = Punch::Email.parse(ADMIN_EMAIL).as(Punch::Email)
  unless seed.read { |db| Punch::Auth::EmailIdentities.find(db, email) }
    password = Random::Secure.urlsafe_base64(15)
    seed.submit(Accounts::SignUp::Create.action, form: {"name" => "Admin", "email" => ADMIN_EMAIL, "password" => password})
    File.write(PASSWORD_FILE, "#{password}\n", perm: 0o600)
    seed.say "Signed up #{ADMIN_EMAIL}; its password is in #{PASSWORD_FILE}."
  end
  identity = seed.read { |db| Punch::Auth::EmailIdentities.find(db, email) } || raise "#{ADMIN_EMAIL} was not signed up"
  # As if its link had been followed, so the password signs in.
  seed.write { |db| Punch::Auth::EmailIdentities.verify(db, email) }
  # The ops console at /_punch (lib/punch/docs/ops.md); no Command gives a global role.
  seed.write { |db| Punch::Roles.assign(db, identity.user_id, Accounts::Roles::Operator) }
  seed.say "#{ADMIN_EMAIL} holds Accounts::Roles::Operator."
end
