module Punch
  # Who a request acts for: a user, and the session or API token that
  # proved it. The app turns it into its own `Auth::Actor`.
  struct Auth::Principal
    getter user_id : Int64
    getter via : Auth::Session | Auth::APIToken

    def initialize(@user_id : Int64, @via : Auth::Session | Auth::APIToken)
    end

    # The user's ID as the app's typed ID: `principal.user_id(Users::ID)`.
    def user_id(type : T.class) : T forall T
      type.parse(@user_id).as(T)
    end

    def session : Auth::Session?
      @via.as?(Auth::Session)
    end

    def api_token : Auth::APIToken?
      @via.as?(Auth::APIToken)
    end
  end

  # Included by the app's actor type, which an operation asks for in its
  # `call` (docs/auth.md):
  #
  # ```
  # struct Invoicing::Actor
  #   include Punch::Auth::Actor
  #
  #   getter user : Accounts::Users::Record
  #   getter principal : Punch::Auth::Principal
  #
  #   def initialize(@user, @principal)
  #   end
  #
  #   # `nil` when the user no longer exists.
  #   def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
  #     Accounts::Users::Table.find(db, principal.user_id(Accounts::Users::ID)).try { |user| new(user, principal) }
  #   end
  # end
  #
  # def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor) : Result   # signed in, else 401
  # def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor?) : Result  # either
  # ```
  #
  # `load` runs in the operation's own transaction, so the operation sees
  # the user as it is in the same snapshot.
  module Auth::Actor
    # The locale the actor chose, stored with the user; it wins over
    # `Accept-Language`. Override it to return the stored tag.
    def locale : LocaleTag?
      nil
    end

    macro included
      macro finished
        \{% unless @type.class.has_method?("load") %}
          \{% raise "#{@type} includes Punch::Auth::Actor, so it needs `def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?` (lib/punch/docs/auth.md)" %}
        \{% end %}
      end
    end
  end

  # 401: the operation needs an actor and the request has none, or it
  # presented a bearer token that is not valid.
  @[Punch::Status(401)]
  struct Auth::Unauthenticated
    include JSON::Serializable

    def initialize
    end
  end

  # The request's sign-in state, for the Commands that change it: sign in,
  # sign out, and renew after a change of privilege. A Command asks for it
  # in its `call`:
  #
  # ```
  # def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : SignedIn | Rejected
  #   ...
  #   auth.sign_in(user.id, method: "password")
  # end
  # ```
  #
  # Cookie changes reach the response only when the Command commits.
  class Auth::Authentication
    # A `Set-Cookie` change waiting for the response: the new cookie value,
    # or `nil` to clear it.
    # :nodoc:
    getter cookie : {Secret(String)?, Time}?
    # The same for the second-factor challenge.
    # :nodoc:
    getter challenge : {Secret(String)?, Time}?
    getter principal : Auth::Principal?

    def initialize(@db : Writer, @principal : Auth::Principal?, *, @now : Time = Time.utc, @ip : String? = nil,
                   @user_agent : String? = nil, @config : Auth::Config = Auth.config)
    end

    # The session the request came with, if it is live.
    def session : Auth::Session?
      @principal.try(&.session)
    end

    # Signs *user_id* in after the first step, *method*, such as
    # `password` or `magic_link`, and ends the session the request came
    # with, so a session ID never survives a sign-in. Returns the new
    # session, or `Auth::SecondFactorRequired` when the user has a confirmed
    # second factor: then no session exists yet, and the browser holds a
    # challenge for a Command that takes `Punch::Auth::SecondFactorCheck`.
    def sign_in(user_id : TypedID | Int64, *, method : String) : Auth::Session | Auth::SecondFactorRequired
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      return start(raw, method) if Auth::SecondFactors.enabled?(@db, raw)

      session.try { |current| Auth::Sessions.revoke(@db, current.id) }
      created, token = Auth::Sessions.create(@db, raw, method, now: @now, ip: @ip, user_agent: @user_agent, config: @config)
      @principal = Auth::Principal.new(raw, created)
      @cookie = {token, created.expires_at}
      created
    end

    # The second step passed: the session, with the challenge cleared.
    # :nodoc:
    def complete_second_factor(user_id : Int64, method : String) : Auth::Session
      session.try { |current| Auth::Sessions.revoke(@db, current.id) }
      created, token = Auth::Sessions.create(@db, user_id, method, now: @now, ip: @ip, user_agent: @user_agent, config: @config)
      @principal = Auth::Principal.new(user_id, created)
      @cookie = {token, created.expires_at}
      @challenge = {nil, @now}
      created
    end

    # The first step passed for a user with a second factor: the session
    # the request came with ends, and a challenge waits for the code.
    private def start(user_id : Int64, method : String) : Auth::SecondFactorRequired
      raise ArgumentError.new("sign-in method must be lowercase letters, digits, _ and +, got #{method.inspect}") unless Auth::Sessions::METHOD.matches?(method)
      if current = session
        Auth::Sessions.revoke(@db, current.id)
        @cookie = {nil, @now}
      end
      @principal = nil
      token = Auth::OneTimeTokens.issue(@db, Auth::SecondFactors::CHALLENGE, @config.second_factor_timeout, user_id: user_id, subject: method, now: @now)
      @challenge = {token, @now + @config.second_factor_timeout}
      Auth::SecondFactorRequired.new
    end

    # Ends the request's session, if any, and clears the cookie.
    def sign_out : Nil
      session.try { |current| Auth::Sessions.revoke(@db, current.id) }
      @principal = nil
      @cookie = {nil, @now}
    end

    # Gives the session a new ID after a change of privilege. With
    # *method*, the user has just proved who they are again. `nil` without
    # a session.
    def renew(*, method : String? = nil) : Auth::Session?
      current = session || return
      renewed, token = Auth::Sessions.renew(@db, current, method: method, now: @now) || return
      @principal = Auth::Principal.new(renewed.user_id, renewed)
      @cookie = {token, renewed.expires_at}
      renewed
    end

    # Writes the waiting cookie change into *context*.
    # :nodoc:
    def apply(context : HTTP::Context) : Nil
      if change = @cookie
        token, expires_at = change
        context.cookies << (token ? Auth.cookie(token, expires_at - @now) : Auth.clear_cookie)
      end
      if change = @challenge
        token, expires_at = change
        context.cookies << (token ? Auth.cookie(token, expires_at - @now, Auth::CHALLENGE_COOKIE) : Auth.clear_cookie(Auth::CHALLENGE_COOKIE))
      end
    end
  end

  module Auth
    # Answer of `authenticate` when a bearer token was presented and is
    # not valid: 401 even where an actor is optional.
    record Refused

    # Finds who *context*'s request acts for, in the operation's
    # transaction. A bearer token wins over the session cookie, which is
    # then ignored. A cookie that names no live session is cleared. With a
    # `Writer`, a due last-seen time is written at once; with a `Reader`,
    # after the read (`touch_later`).
    def self.authenticate(context : HTTP::Context, db : Reader | Writer, now : Time) : Auth::Principal | Refused?
      span = context.span
      request = context.request
      principal = if header = request.headers["Authorization"]?
                    token = bearer(header)
                    found = token ? Auth::APITokens.find(db, token, now: now) : nil
                    unless found
                      span.set("punch.auth", "refused") if span.recording?
                      return Refused.new
                    end
                    found = touched(context, db, found, now)
                    Auth::Principal.new(found.user_id, found)
                  elsif value = request.cookies[COOKIE]?.try(&.value)
                    unless found = Auth::Sessions.find(db, value, now: now)
                      context.cookies << clear_cookie
                      span.set("punch.auth", "expired") if span.recording?
                      return
                    end
                    found = touched(context, db, found, now)
                    Auth::Principal.new(found.user_id, found)
                  end
      return unless principal

      if span.recording?
        span.set("punch.auth", principal.via.is_a?(Auth::Session) ? "session" : "token")
        span.set("user.id", principal.user_id)
      end
      context.principal = principal
    end

    private def self.touched(context : HTTP::Context, db : Reader | Writer, found : Auth::Session | Auth::APIToken, now : Time) : Auth::Session | Auth::APIToken
      return found unless found.touch_due?(now)

      if db.is_a?(Writer)
        case found
        in Auth::Session  then Auth::Sessions.touch(db, found, now: now)
        in Auth::APIToken then Auth::APITokens.touch(db, found, now: now)
        end
      else
        context.touch = found
        found
      end
    end

    # Writes a last-seen time that a Query found due, after its read.
    def self.touch_later(context : HTTP::Context, database : Database, now : Time) : Nil
      found = context.touch || return
      context.touch = nil
      database.write do |db|
        case found
        in Auth::Session  then Auth::Sessions.touch(db, found, now: now)
        in Auth::APIToken then Auth::APITokens.touch(db, found, now: now)
        end
      end
    end

    # Whether the request presents a session cookie or an `Authorization`
    # header, so an operation that needs an actor can answer 401 without
    # opening a transaction.
    def self.presented?(context : HTTP::Context) : Bool
      request = context.request
      request.headers.has_key?("Authorization") || request.cookies.has_key?(COOKIE)
    end

    # The token in `Authorization: Bearer <token>`, or `nil`.
    def self.bearer(header : String) : String?
      scheme, _, token = header.strip.partition(' ')
      token = token.strip
      token if scheme.compare("Bearer", case_insensitive: true).zero? && !token.empty?
    end

    # The 401 answer, with the challenge RFC 9110 requires.
    def self.unauthenticated(context : HTTP::Context) : HTTP::Response
      context.span.set("punch.outcome", "unauthenticated")
      response = HTTP::Response.problem(:unauthorized, context, "unauthenticated")
      response.headers["WWW-Authenticate"] = challenge(context)
      response
    end

    # The `WWW-Authenticate` value of a 401, which RFC 9110 requires.
    def self.challenge(context : HTTP::Context) : String
      context.request.headers.has_key?("Authorization") ? %(Bearer error="invalid_token") : "Bearer"
    end

    # The session cookie carrying *token*, kept by the browser for *max_age*.
    def self.cookie(token : Secret(String), max_age : Time::Span, name : String = COOKIE) : String
      "#{name}=#{token.unwrap}; Path=/; Max-Age=#{max_age.total_seconds.to_i64.clamp(0, nil)}; Secure; HttpOnly; SameSite=Lax"
    end

    def self.clear_cookie(name : String = COOKIE) : String
      "#{name}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"
    end
  end
end
