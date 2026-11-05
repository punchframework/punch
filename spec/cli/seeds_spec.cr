require "../spec_helper"
require "../support/auth_schema"
require "../../src/punch/seeds"

module SeedsSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  module Notes
    @[Punch::Status(201)]
    struct Added
      include JSON::Serializable

      def initialize
      end
    end

    # Adds a note for the signed-in user; refuses the title "taken".
    @[Punch::Authorize(Punch::SignedIn)]
    struct Create < Punch::Command
      struct Input
        include Punch::Input

        getter title : Punch::NonEmptyString
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, _grant : Punch::Grant(Create)) : Added | Punch::Rejection
        if input.title.value == "taken"
          return Punch::Rejection.new(Punch::Rejection::Path{"title"}, Punch::Invalid.new("taken"))
        end

        db.exec("INSERT INTO seed_notes (user_id, title) VALUES (?, ?)", actor.principal.user_id, input.title.value)
        Added.new
      end
    end
  end

  module Notes
    struct NoteForm
      include Punch::Component

      def view(v : Punch::View) : Nil
        v.form(Create.action) do |form|
          form.field :title
          form.submit "Add"
        end
      end
    end

    # The page that holds the form: where a refusal is shown again.
    @[Punch::Authorize(Punch::SignedIn)]
    struct CreatePage < Punch::Page
      struct Input
        include Punch::Input
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : NoteForm
        NoteForm.new
      end

      def self.redirect(result : Added) : Punch::Href
        CreatePage.href
      end
    end
  end

  SQL = "CREATE TABLE seed_notes (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, title TEXT NOT NULL) STRICT;\n"
end

describe Punch::Seed do
  it "sends the app's forms through its router, as the user it signed in" do
    AuthSchema.with_spec_db(SeedsSpec::SQL) do
      seed = Punch::Seed.new(Punch::Spec.db).sign_in(1_i64)
      seed.submit(SeedsSpec::Notes::Create.action, form: {"title" => "First"}).status_code.should eq(303)
      seed.read(&.query_one?("SELECT user_id || ':' || title FROM seed_notes", &.read(String))).should eq("1:First")
    end
  end

  it "stops at a refusal, naming its codes" do
    AuthSchema.with_spec_db(SeedsSpec::SQL) do
      seed = Punch::Seed.new(Punch::Spec.db)
      expect_raises(Punch::Seeds::Failed, /answered 401/) { seed.submit(SeedsSpec::Notes::Create.action, form: {"title" => "Anyone"}) }
      seed.sign_in(2_i64)
      expect_raises(Punch::Seeds::Failed, /answered 422: taken/) { seed.submit(SeedsSpec::Notes::Create.action, form: {"title" => "taken"}) }
      seed.read(&.query_one?("SELECT count(*) FROM seed_notes", &.read(Int64))).should eq(0)
    end
  end
end
