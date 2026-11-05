require "../../src/punch"

module Accounts
  @[Punch::RateLimit(5, per: 1.minute, by: :email)]
  @[Punch::Public]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input
      getter email : Punch::Email
      getter password : String
    end

    def call(input : Input, db : Punch::Writer, password : Punch::Auth::PasswordCheck) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
