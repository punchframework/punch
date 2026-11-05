# Fixture for Punch/PasswordCheck: checking a password around PasswordCheck.
module Accounts::Sessions
  struct Create < Punch::Command
    def call(input : Input, db : Punch::Writer) : Output
      found = Punch::Auth::Passwords.lookup(db, input.email) || return Punch::Auth::InvalidCredentials.new # expect
      user_id, stored = found
      verdict = Punch::Auth::Passwords.verify_now(input.password.unwrap, stored || "") # expect
      again = Auth::Passwords.stored(db, user_id)                                      # expect
      hasher = Punch::Auth::Passwords.hasher                                           # expect
      alias_check = Hashing.verify_now(input.password.unwrap, stored || "")            # expect
      fresh = Punch::Auth::Passwords.hash_now("secret")                                # expect
      Punch::Auth::Passwords.current?(stored || "")
      input.email.stored
    end
  end
end
