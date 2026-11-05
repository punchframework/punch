require "./cli"

module Punch
  # Development data (`db/seeds.cr`, run by `punch db:seed`; docs/tooling.md).
  # A seed is plain Crystal that sends the app's own Commands, as a browser
  # would, through the router in this process: seeded data passes the same
  # rules as real data. It opens the files as `serve` does (migrations,
  # credentials, Punch's tables) and refuses outside development.
  #
  # ```
  # require "../src/tally"
  # require "punch/seeds"
  #
  # Punch::Seeds.run do |seed|
  #   email = Punch::Email.parse("admin@example.test").as(Punch::Email)
  #   unless seed.read { |db| Punch::Auth::EmailIdentities.find(db, email) }
  #     seed.submit(Accounts::SignUp::Create.action, form: {"name" => "Admin", "email" => email.value, "password" => PASSWORD})
  #   end
  # end
  # ```
  #
  # Write a seed so that running it again is safe: look before adding.
  module Seeds
    # A Command answered with a failure, or the app raised.
    class Failed < Exception
    end

    # Boots against the development files in `PUNCH_STORAGE`, yields a
    # `Seed`, and exits: 0 when the block finished, 1 with the reason
    # otherwise. Jobs the seed's Commands enqueue wait in the outbox for
    # the next `punch dev`.
    def self.run(env = ENV, & : Seed ->) : NoReturn
      settings = AppConfig.from(env)
      abort_with(settings.join("\n")) if settings.is_a?(Array(String))
      unless settings.environment == "development"
        abort_with("Seeds are for development; PUNCH_ENV is #{settings.environment}.")
      end
      booted = CLI::Commands::Serve.boot(settings) { }
      abort_with(booted.message) if booted.is_a?(CLI::Failure)
      databases, _ = booted
      begin
        yield Seed.new(databases.primary)
      rescue ex : Failed
        abort_with(ex.message || "a seed failed")
      ensure
        databases.close
      end
      exit 0
    end

    private def self.abort_with(message : String) : NoReturn
      STDERR.puts "punch db:seed: #{message}"
      exit 1
    end
  end

  # What a seed works with: forms and requests through the app's router,
  # with the cookies a browser keeps (a sign-up signs in), and the primary
  # database for what no Command does, such as giving a global role.
  class Seed
    getter database : Database

    def initialize(@database : Database)
      router = Routing::Router.new(@database)
      @server = HTTP::Server.new(HTTP::Config.new, Trace::Tracer.off) { |context| router.call(context) }
      @cookies = {} of String => String
    end

    # Sends a form to *action* as a browser does, and follows nothing:
    # returns the answer. *values* are typed like the Command's input
    # (`View#form`); *form* sends fields as text, as a person types them.
    # Raises `Seeds::Failed` when the Command refused (400 and up), naming
    # its errors.
    def submit(action : Action(C), values : NamedTuple? = nil, *, form : Hash(String, String)? = nil) : ::HTTP::Client::Response forall C
      params = Input::Form.encode(C::Input, values)
      form.try &.each { |key, value| params.add(key, value) }
      if Routing.idempotency(C) == :required
        params.add(IdempotencyKeys::FIELD, Random::Secure.urlsafe_base64(18))
      end
      headers = ::HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded",
                                "Accept" => "text/html", "Sec-Fetch-Site" => "same-origin"}
      request("POST", action.url, params.to_s, headers)
    end

    # Any request, for JSON endpoints: *json* is sent as the body.
    def request(method : String, path : String, json, headers : ::HTTP::Headers = ::HTTP::Headers.new) : ::HTTP::Client::Response
      headers["Content-Type"] = "application/json"
      request(method, path, json.to_json, headers)
    end

    # Acts as *user_id* from now on: a new session, as after signing in.
    def sign_in(user_id : TypedID | Int64) : self
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      _, token = @database.write { |db| Auth::Sessions.create(db, raw, "seed") }
      @cookies[Auth::COOKIE] = token.unwrap
      self
    end

    def read(&block : Reader -> T) : T forall T
      @database.read(&block)
    end

    def write(&block : Writer -> T) : T forall T
      @database.write(&block)
    end

    # A line of what the seed did, for the person who ran it.
    def say(text : String) : Nil
      puts text
    end

    private def request(method : String, path : String, body : String, headers : ::HTTP::Headers) : ::HTTP::Client::Response
      headers["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" } unless @cookies.empty?
      response = @server.process(::HTTP::Request.new(method, path, headers, body), "127.0.0.1")
      response.live.try(&.discard)
      keep_cookies(response.headers)
      if raised = response.exception
        raise Seeds::Failed.new("#{method} #{path} raised #{raised.class}: #{raised.message}", cause: raised)
      end
      if response.status.code >= 400
        raise Seeds::Failed.new("#{method} #{path} answered #{response.status.code}: #{Seed.summary(response.body)}")
      end
      ::HTTP::Client::Response.new(response.status, response.body, response.headers)
    end

    private def keep_cookies(headers : ::HTTP::Headers) : Nil
      (headers.get?("Set-Cookie") || return).each do |line|
        cookie = ::HTTP::Cookie::Parser.parse_set_cookie(line) || next
        if cookie.max_age.try { |age| age <= Time::Span.zero } || cookie.value.empty?
          @cookies.delete(cookie.name)
        else
          @cookies[cookie.name] = cookie.value
        end
      end
    end

    # The error codes in a refused form's page or a Problem Details body,
    # so a failed seed says what was wrong without a page of HTML.
    def self.summary(body : String) : String
      codes = body.scan(/data-code="([a-z_]+)"|"code":\s*"([a-z_]+)"/).map { |match| match[1]? || match[2] }.uniq!
      codes.empty? ? body[0, 200] : codes.join(", ")
    end
  end
end
