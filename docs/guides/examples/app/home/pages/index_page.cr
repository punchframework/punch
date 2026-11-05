module Home
  struct Welcome
    include Punch::Component

    def initialize(@actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.home
      v.render Examples::Layout.new(t.title, @actor) do
        v.h1 t.title
        v.p t.intro
      end
    end
  end

  # `GET /`: the first page after signing in (`Accounts::Sessions::CreatePage`
  # and the other sign-in pages redirect here). A browser without a session
  # goes to sign in.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Route("GET", "/")]
  struct IndexPage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = Welcome

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      Welcome.new(actor)
    end
  end
end
