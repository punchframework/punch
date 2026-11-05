require "../../src/punch"

module Accounts
  @[Punch::Public]
  struct Peek < Punch::Query
    struct Input
      include Punch::Input
      getter email : Punch::Email
      getter password : Punch::Auth::Password
    end

    def call(input : Input, db : Punch::Reader, password : Punch::Auth::PasswordCheck) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
