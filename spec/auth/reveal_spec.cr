require "../spec_helper"
require "../support/auth_schema"

module RevealSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  @[Punch::Status(201)]
  struct Created
    include JSON::Serializable

    getter token : String

    def initialize(@token)
    end
  end

  @[Punch::Status(409)]
  struct Refused
    include JSON::Serializable

    def initialize
    end
  end

  struct TokensView
    include Punch::Component

    def initialize(@shown : String?)
    end

    def view(v : Punch::View) : Nil
      v.document("Tokens") do
        v.h1 "Tokens"
        if shown = @shown
          v.p { v.code shown, id: "new-token" }
        end
        v.form(Tokens::Create.action) do |form|
          form.field :name
          form.submit "Create"
        end
      end
    end
  end

  module Tokens
    @[Punch::Public]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter name : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, reveal : Punch::Auth::Reveal) : Created | Refused
        secret = Punch::Secret.new("tok_#{input.name}")
        reveal.once(secret)
        return Refused.new if input.name == "refused"

        Created.new(secret.unwrap)
      end
    end

    @[Punch::Forms(Create)]
    @[Punch::Public]
    struct IndexPage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor, reveal : Punch::Auth::Reveal) : TokensView
        TokensView.new(reveal.take.try(&.unwrap))
      end
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.with_ring(&) : Nil
    previous = Punch::KeyRing.current?
    Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)])
    AuthSchema.with_spec_db { yield }
  ensure
    previous.try { |ring| Punch::KeyRing.current = ring }
  end

  def self.reveal_cookie(response : Punch::Spec::Response) : String?
    response.headers.get?("Set-Cookie").try(&.find(&.starts_with?("#{Punch::Auth::Reveal::COOKIE}=")))
  end
end

describe Punch::Auth::Reveal do
  it "shows a Command's secret once, on the page the browser lands on" do
    RevealSpec.with_ring do
      client = RevealSpec.client.sign_in(1_i64)
      sent = client.submit(RevealSpec::Tokens::Create.action, {name: "ci"})
      sent.should redirect_to(RevealSpec::Tokens::IndexPage.href)
      cookie = RevealSpec.reveal_cookie(sent) || fail "no reveal cookie"
      cookie.should end_with("; Path=/; Max-Age=60; Secure; HttpOnly; SameSite=Strict")
      cookie.should_not contain("tok_ci")

      shown = client.visit(sent.headers["Location"])
      shown.should have_element("#new-token", text: "tok_ci")
      RevealSpec.reveal_cookie(shown).should eq("#{Punch::Auth::Reveal::COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict")
      client.visit(RevealSpec::Tokens::IndexPage.href).should_not have_element("#new-token")
    end
  end

  it "leaves nothing when the Command fails" do
    RevealSpec.with_ring do
      client = RevealSpec.client.sign_in(1_i64)
      refused = client.submit(RevealSpec::Tokens::Create.action, {name: "refused"})
      refused.status.should eq(HTTP::Status::CONFLICT)
      RevealSpec.reveal_cookie(refused).should be_nil
    end
  end

  it "gives a bearer client the secret in the body only" do
    RevealSpec.with_ring do
      client = RevealSpec.client
      created = client.post(RevealSpec::Tokens::Create.path, json: {name: "agent"}, headers: Punch::Spec.bearer(Punch::Spec.api_token(1_i64)))
      created.status.should eq(HTTP::Status::CREATED)
      created.json["token"].should eq("tok_agent")
      RevealSpec.reveal_cookie(created).should be_nil
    end
  end

  it "shows nothing to another session, and clears the cookie there" do
    RevealSpec.with_ring do
      client = RevealSpec.client.sign_in(1_i64)
      sent = client.submit(RevealSpec::Tokens::Create.action, {name: "ci"})
      other = RevealSpec.client.sign_in(1_i64)
      other.cookies[Punch::Auth::Reveal::COOKIE] = client.cookies[Punch::Auth::Reveal::COOKIE]
      page = other.visit(sent.headers["Location"])
      page.should_not have_element("#new-token")
      RevealSpec.reveal_cookie(page).should eq("#{Punch::Auth::Reveal::COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict")
    end
  end

  it "refuses an altered or expired cookie" do
    RevealSpec.with_ring do
      client = RevealSpec.client.sign_in(1_i64)
      client.submit(RevealSpec::Tokens::Create.action, {name: "ci"})
      value = client.cookies[Punch::Auth::Reveal::COOKIE]
      session = Punch::Spec.db.read { |db| Punch::Auth::Sessions.find(db, client.cookies[Punch::Auth::COOKIE]) } || fail "no session"
      principal = Punch::Auth::Principal.new(1_i64, session)
      take = ->(cookie : String, at : Time) {
        request = HTTP::Request.new("GET", "/", HTTP::Headers{"Cookie" => "#{Punch::Auth::Reveal::COOKIE}=#{cookie}"})
        Punch::Auth::Reveal.new(principal, Punch::HTTP::Context.new(request, "127.0.0.1", Punch::HTTP::Config.new), at).take.try(&.unwrap)
      }
      take.call(value, Time.utc).should eq("tok_ci")
      take.call(value, Time.utc + 2.minutes).should be_nil
      altered = value.sub(value[-2], value[-2] == 'A' ? 'B' : 'A')
      take.call(altered, Time.utc).should be_nil
      take.call("not base64!", Time.utc).should be_nil
    end
  end

  it "takes no idempotency key" do
    RevealSpec.with_ring do
      Punch::Routing.idempotency(RevealSpec::Tokens::Create).should eq(:none)
      client = RevealSpec.client
      refused = client.post(RevealSpec::Tokens::Create.path, json: {name: "agent"},
        headers: Punch::Spec.bearer(Punch::Spec.api_token(1_i64)).merge!({"Idempotency-Key" => "k1"}))
      refused.status.should eq(HTTP::Status::BAD_REQUEST)
      refused.json["code"].should eq("idempotency_key_not_accepted")
    end
  end
end
