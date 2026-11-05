require "../../src/punch"

@[Punch::Public]
@[Punch::RateLimit(5, per: 1.minute, by: :email)]
struct SignIn < Punch::Command
  struct Input
    include Punch::Input
    getter email : Punch::Email
    getter password : Punch::Auth::Password
  end

  def call(input : Input, db : Punch::Writer, password : Punch::Auth::PasswordCheck) : Punch::Auth::InvalidCredentials?
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
