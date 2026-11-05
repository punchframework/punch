module Punch
  # A secret shown once, to the browser session that made it, on the page
  # it lands on after the form (docs/auth.md, "Showing a new token once").
  # A form's success is a `303 See Other` (Turbo Drive expects one), so a
  # new API token cannot be in that answer; it travels to the next page in
  # a cookie instead, encrypted with the key ring, bound to the session,
  # for 10 minutes, and cleared by the page that shows it. Nothing is
  # stored on the server: the token's row keeps its digest only.
  #
  # ```
  # # A Command: a JSON client gets the token in the body, a browser on the next page.
  # def call(input : Input, db : Punch::Writer, actor : Actor, reveal : Punch::Auth::Reveal) : Created
  #   token, secret = ...
  #   reveal.once(secret)
  #   Created.new(token, secret.unwrap)
  # end
  #
  # # The page the browser lands on.
  # def call(input : Input, db : Punch::Reader, actor : Actor, reveal : Punch::Auth::Reveal) : ListView
  #   ListView.new(..., reveal.take.try(&.unwrap))
  # end
  # ```
  #
  # Both take the app's actor; only a session's browser gets the cookie (a
  # bearer client has the token in the body). A Command that takes it
  # accepts no idempotency key, which would store the token in its answer.
  class Auth::Reveal
    COOKIE  = "__Host-reveal"
    PURPOSE = "punch.reveal"
    # Long enough for the redirect to the page that shows it.
    LIFETIME = 1.minute

    @value : Secret(String)?
    @presented : String?
    @taken = false

    # :nodoc:
    def initialize(@principal : Auth::Principal?, context : HTTP::Context, @now : Time = Time.utc)
      @presented = context.request.cookies[COOKIE]?.try(&.value)
    end

    # Shows *secret* once on the next page this browser opens that takes a
    # `Punch::Auth::Reveal`, if the Command succeeds. The last call wins.
    def once(secret : Secret(String)) : Nil
      @value = secret
    end

    # The secret a Command left for this session, or `nil`: none, expired,
    # altered, or another session's. The page clears it either way, so it
    # is shown once.
    def take : Secret(String)?
      @taken = true
      presented = @presented || return
      session = @principal.try(&.session) || return
      sealed = Base64.decode(presented) rescue return
      plain = String.new(KeyRing.current.encryptor(PURPOSE).decrypt(sealed) || return)
      owner, expires, value = plain.split('\n', 3)
      return unless owner == session.id.to_s && (expires.to_i64? || return) > @now.to_unix

      Secret.new(value)
    rescue IndexError
    end

    # Sets the cookie after a Command committed, or clears the one a page
    # took.
    # :nodoc:
    def apply(context : HTTP::Context) : Nil
      if (value = @value) && (session = @principal.try(&.session))
        expires = (@now + LIFETIME).to_unix
        sealed = KeyRing.current.encryptor(PURPOSE).encrypt("#{session.id}\n#{expires}\n#{value.unwrap}".to_slice)
        context.cookies << "#{COOKIE}=#{Base64.urlsafe_encode(sealed, padding: false)}; Path=/; Max-Age=#{LIFETIME.total_seconds.to_i}; Secure; HttpOnly; SameSite=Strict"
      elsif @taken && @presented
        context.cookies << "#{COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
      end
    end
  end
end
