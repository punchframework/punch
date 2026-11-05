module Accounts::Sessions
  # Ends this browser's session.
  @[Punch::Authorize(Punch::SignedIn)]
  struct SignOut < Punch::Command
    struct Input
      include Punch::Input
    end

    alias Output = SignedOut

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(SignOut),
             events : Punch::Events(Punch::Auth::SessionRevoked)) : Output
      auth.session.try { |session| events.publish(Punch::Auth::SessionRevoked.new(actor.user.id.value, session.id, "sign_out")) }
      auth.sign_out
      SignedOut.new
    end
  end
end
