require "../../src/punch"

module Accounts
  @[Punch::RateLimit(20, per: 1.minute, by: :ip)]
  @[Punch::Public]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input
      getter email : Punch::Email
      getter password : Punch::Auth::Password
    end

    def call(input : Input, db : Punch::Writer, password : Punch::Auth::PasswordCheck) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
