require "../spec_helper"
require "../support/auth_schema"

module I18nSpec
  # Users 1 and 2 exist (AuthSchema); user 2 chose German.
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end

    def locale : Punch::LocaleTag?
      Punch::LocaleTag.parse("de-CH").as(Punch::LocaleTag) if principal.user_id == 2
    end
  end

  struct Greeting
    include JSON::Serializable

    getter text : String

    def initialize(@text)
    end
  end

  module Notes
    # Answers in the request's locale: a Query takes `Punch::Locale`.
    @[Punch::Public]
    struct Greet < Punch::Query
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, locale : Punch::Locale) : Greeting
        Greeting.new("#{locale.code}: #{locale.date(Time.utc(2026, 3, 5), :long)}")
      end
    end

    # Renders nothing in a locale.
    @[Punch::Public]
    struct Ping < Punch::Query
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader) : Greeting
        Greeting.new("pong")
      end
    end

    @[Punch::Status(409)]
    struct AlreadySent
      include JSON::Serializable

      getter state : String

      def initialize(@state)
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter title : Punch::NonEmptyString
        getter weight : Int32
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Create)) : AlreadySent?
        AlreadySent.new("sent") if input.title.to_s == "sent"
      end
    end

    @[Punch::Authorize(Punch::SignedIn)]
    struct CreatePage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : Form
        Form.new
      end
    end

    struct Form
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.document("New note") do
          v.form(Create.action) do |form|
            form.field :title
            form.field :weight
            form.submit "Save"
          end
        end
      end
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end
end

describe "requests in a locale" do
  it "renders rejections in the language Accept-Language asks for, and says so" do
    AuthSchema.with_spec_db do
      client = I18nSpec.client.sign_in(1_i64)
      german = client.post(I18nSpec::Notes::Create.path, json: {title: "", weight: "x"}, headers: HTTP::Headers{"Accept-Language" => "de-DE,de;q=0.9"})
      german.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      german.json["detail"].should eq("Einige Eingaben sind ungültig.")
      german.json["errors"].as_a.map { |error| {error["code"].as_s, error["message"].as_s} }.should eq([
        {"blank", "Darf nicht leer sein."},
        {"expected_integer", "Muss eine ganze Zahl sein."},
      ])
      german.headers["Content-Language"].should eq("de")
      german.headers["Vary"].should contain("Accept-Language")
      german.trace.root.attributes["punch.locale"].should eq("de")

      english = client.post(I18nSpec::Notes::Create.path, json: {title: "", weight: 1})
      english.json["errors"][0]["message"].should eq("Must not be empty.")
      english.headers["Content-Language"].should eq("en")
      english.headers["Vary"]?.should be_nil
    end
  end

  it "fills a failure result's fields into its message" do
    AuthSchema.with_spec_db do
      response = I18nSpec.client.sign_in(1_i64).post(I18nSpec::Notes::Create.path, json: {title: "sent", weight: 1})
      response.status.should eq(HTTP::Status::CONFLICT)
      response.json["code"].should eq("already_sent")
      response.json["state"].should eq("sent")
      response.json["detail"]?.should be_nil
    end
  end

  it "prefers the actor's stored locale over Accept-Language" do
    AuthSchema.with_spec_db do
      response = I18nSpec.client.sign_in(2_i64).post(I18nSpec::Notes::Create.path, json: {title: "", weight: 1},
        headers: HTTP::Headers{"Accept-Language" => "en"})
      response.json["errors"][0]["message"].should eq("Darf nicht leer sein.")
      response.headers["Content-Language"].should eq("de")
      response.headers["Vary"]?.should be_nil
    end
  end

  it "passes the locale to operations that take it" do
    client = I18nSpec.client
    client.get(I18nSpec::Notes::Greet.path).json["text"].should eq("en: March 5, 2026")
    client.language = "de"
    client.get(I18nSpec::Notes::Greet.path).json["text"].should eq("de: 5. März 2026")
  end

  it "leaves responses that render nothing in a locale alone" do
    response = I18nSpec.client.get(I18nSpec::Notes::Ping.path, headers: HTTP::Headers{"Accept-Language" => "de"})
    response.headers["Content-Language"]?.should be_nil
  end

  it "renders pages, labels, and form errors in the request's locale" do
    AuthSchema.with_spec_db do
      client = I18nSpec.client.sign_in(1_i64)
      client.language = "de"
      page = client.visit(I18nSpec::Notes::CreatePage.href)
      page.should have_element("html[lang=de]")
      page.headers["Content-Language"].should eq("de")

      refused = client.submit(I18nSpec::Notes::Create.action, form: {"title" => "", "weight" => "x"})
      refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      refused.should have_field_error("title", "required")
      refused.should have_element(".field-error[data-code=expected_integer]", text: "Muss eine ganze Zahl sein.")
      refused.should have_element(".form-errors p", text: "Bitte korrigieren Sie:")
      refused.should have_element(".form-errors li[data-code=required]", text: "Title: Muss angegeben werden.")
    end
  end

  it "renders Punch's problem page in the request's locale" do
    client = I18nSpec.client
    client.language = "de"
    page = client.visit("/i18n_spec/nowhere")
    page.status.should eq(HTTP::Status::NOT_FOUND)
    page.should have_element("p", text: "Hier gibt es nichts.")
    page.should have_element("html[lang=de]")
    client.get("/i18n_spec/nowhere").json["detail"].should eq("Hier gibt es nichts.")
  end
end
