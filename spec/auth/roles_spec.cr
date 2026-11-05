require "../spec_helper"
require "../support/auth_schema"

module RolesSpec
  struct UserID < Punch::TypedID
  end

  module Teams
    struct ID < Punch::TypedID
    end
  end

  module Docs
    struct ID < Punch::TypedID
    end
  end

  struct Actor
    include Punch::Auth::Actor

    getter id : UserID

    def initialize(@id)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal.user_id(UserID))
    end
  end

  # Ada edits team 1, Grace views it; team 2 is nobody's.
  SQL = <<-SQL
    CREATE TABLE docs (id INTEGER PRIMARY KEY, team_id INTEGER NOT NULL, title TEXT NOT NULL) STRICT;
    INSERT INTO docs (id, team_id, title) VALUES (1, 1, 'Plan'), (2, 1, 'Budget'), (3, 2, 'Secret'), (4, 1, 'Notes');
    SQL

  # A doc is reached through its team: the roles held on the team decide.
  struct TeamRoles
    include Punch::Policy

    def self.check(actor : Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *, doc_id : Docs::ID) : Punch::Policy::Decision
      team = db.query_one?("SELECT team_id FROM docs WHERE id = ?", doc_id.value, &.read(Int64)) || return allow
      Punch::Roles.check(db, actor.id, operation, on: Teams::ID.parse(team).as(Teams::ID))
    end
  end

  struct Doc
    include JSON::Serializable

    getter title : String

    def initialize(@title)
    end
  end

  struct Titles
    include JSON::Serializable

    getter titles : Array(String)

    def initialize(@titles)
    end
  end

  module Docs
    @[Punch::Authorize(TeamRoles)]
    struct Show < Punch::Query
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter doc_id : Docs::ID
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : Doc
        Doc.new(db.query_one?("SELECT title FROM docs WHERE id = ?", input.doc_id.value, &.read(String)) || "")
      end
    end

    @[Punch::Authorize(TeamRoles)]
    struct Update < Punch::Command
      struct Input
        include Punch::Input

        @[Punch::PathParam]
        getter doc_id : Docs::ID

        getter title : String
      end

      def call(input : Input, db : Punch::Writer, actor : Actor, grant : Punch::Grant(Update)) : Doc
        db.exec("UPDATE docs SET title = ? WHERE id = ?", input.title, input.doc_id.value)
        Doc.new(input.title)
      end
    end

    # Every doc the actor may see, by the effective permissions: a team
    # role that permits it, or a global one.
    @[Punch::Authorize(Punch::SignedIn)]
    struct Index < Punch::Query
      struct Input
        include Punch::Input

        getter limit : Int32 = 2
      end

      def call(input : Input, db : Punch::Reader, actor : Actor) : Titles
        titles = db.query_all(<<-SQL, actor.id.value, actor.id.value, input.limit, &.read(String))
          SELECT d.title FROM docs d
          WHERE d.team_id IN (
              SELECT p.resource_id FROM punch_permissions p
              WHERE p.user_id = ?1 AND p.operation = 'roles_spec.docs.index' AND p.resource_type = 'roles_spec.teams')
            OR EXISTS (
              SELECT 1 FROM punch_permissions p
              WHERE p.user_id = ?2 AND p.operation = 'roles_spec.docs.index' AND p.resource_type IS NULL)
          ORDER BY d.id LIMIT ?3
          SQL
        Titles.new(titles)
      end
    end

    struct DocView
      include Punch::Component

      def initialize(@id : Docs::ID, @doc : Doc)
      end

      def view(v : Punch::View) : Nil
        v.main do
          v.h1 @doc.title
          v.form(Update.action(doc_id: @id)) { |form| form.field :title; form.submit "Rename" }
        end
      end
    end

    @[Punch::Authorize(TeamRoles)]
    @[Punch::Forms(Update)]
    struct ShowPage < Punch::Page
      alias Input = Show::Input

      def call(input : Input, db : Punch::Reader, actor : Actor) : DocView
        DocView.new(input.doc_id, Show.new.call(input, db, actor))
      end
    end
  end

  module Roles
    # Reads a team's docs.
    struct Viewer
      include Punch::Role

      scope Teams::ID
      permits Docs::Index, Docs::Show, Docs::ShowPage
    end

    # A viewer who also renames them.
    struct Editor
      include Punch::Role

      scope Teams::ID
      permits Viewer, Docs::Update
    end

    # Reads every team's docs.
    struct Auditor
      include Punch::Role

      permits Docs::Index, Docs::Show
    end
  end

  def self.with_db(&)
    path = File.tempname("roles-spec", ".sql")
    File.write(path, AuthSchema::SQL + Punch::Roles::Schema.sql + SQL)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    begin
      Punch::Spec.db.write(&.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace'), (3, 'Edsger')"))
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end

  def self.user(id : Int32) : UserID
    UserID.parse(id).as(UserID)
  end

  def self.team(id : Int32) : Teams::ID
    Teams::ID.parse(id).as(Teams::ID)
  end

  def self.doc(id : Int32) : Docs::ID
    Docs::ID.parse(id).as(Docs::ID)
  end

  def self.client(user : Int32) : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil).sign_in(user(user))
  end

  # Ada edits team 1, Grace views it, Edsger holds nothing.
  def self.staff : Nil
    Punch::Spec.db.write do |db|
      Punch::Roles.assign(db, user(1), Roles::Editor, on: team(1))
      Punch::Roles.assign(db, user(2), Roles::Viewer, on: team(1), assigned_by: user(1))
    end
  end
end

describe Punch::Roles do
  it "reads role definitions from the code, with included roles' operations" do
    roles = Punch::Roles.definitions.select(&.name.starts_with?("roles_spec.")).to_h { |role| {role.name, role} }
    roles["roles_spec.roles.viewer"].scope.should eq("roles_spec.teams")
    roles["roles_spec.roles.viewer"].operations.should eq(["roles_spec.docs.index", "roles_spec.docs.show", "roles_spec.docs.show_page"])
    roles["roles_spec.roles.editor"].operations.should eq(["roles_spec.docs.index", "roles_spec.docs.show", "roles_spec.docs.show_page", "roles_spec.docs.update"])
    roles["roles_spec.roles.auditor"].scope.should be_nil
  end

  it "writes the roles' operations when a spec loads the schema, and again only when they differ" do
    RolesSpec.with_db do
      count = -> { Punch::Spec.db.read(&.query_one?("SELECT count(*) FROM punch_role_operations WHERE role LIKE 'roles\\_spec.%' ESCAPE '\\'", &.read(Int64))) }
      count.call.should eq(9)
      Punch::Spec.db.write(&.exec("DELETE FROM punch_role_operations WHERE role = 'roles_spec.roles.auditor'"))
      Punch::Roles.sync(Punch::Spec.db)
      count.call.should eq(9)
    end
  end

  it "assigns, changes the expiry of, and revokes a role" do
    RolesSpec.with_db do
      Punch::Spec.db.write do |db|
        first = Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1), assigned_by: RolesSpec.user(1))
        first.to_s.should eq("roles_spec.roles.viewer on roles_spec.teams 1")
        first.assigned_by.should eq(1)
        later = Time.utc + 1.day
        again = Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1), expires_at: later)
        again.id.should eq(first.id)
        again.expires_at.should eq(later)
        Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Auditor).resource_type.should be_nil
        Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Auditor).id.should eq(Punch::Roles.assignments(db, user_id: 2_i64).last.id)
        Punch::Roles.assignments(db, user_id: RolesSpec.user(2)).size.should eq(2)
        Punch::Roles.holders(db, RolesSpec::Roles::Viewer, on: RolesSpec.team(1)).should eq(1)

        Punch::Roles.revoke(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1)).try(&.id).should eq(first.id)
        Punch::Roles.revoke(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1)).should be_nil
        Punch::Roles.revoke(db, RolesSpec.user(2), RolesSpec::Roles::Auditor).should_not be_nil
        Punch::Roles.assignments(db, user_id: 2_i64).should be_empty
      end
    end
  end

  it "ends every assignment on a deleted resource" do
    RolesSpec.with_db do
      RolesSpec.staff
      Punch::Spec.db.write do |db|
        Punch::Roles.revoke_all(db, on: RolesSpec.team(1)).map(&.user_id).sort!.should eq([1, 2])
        Punch::Roles.assignments(db, on: RolesSpec.team(1)).should be_empty
      end
    end
  end

  it "allows, forbids where another role is held, and hides where nothing is" do
    RolesSpec.with_db do
      RolesSpec.staff
      Punch::Spec.db.read do |db|
        Punch::Roles.check(db, RolesSpec.user(1), RolesSpec::Docs::Update, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Allow)
        Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Show, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Allow)
        Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Update, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Forbid)
        Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Show, on: RolesSpec.team(2)).should eq(Punch::Policy::Decision::NotFound)
        Punch::Roles.check(db, RolesSpec.user(3), RolesSpec::Docs::Show, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::NotFound)
      end
    end
  end

  it "counts a global role on every resource, and an expired one nowhere" do
    RolesSpec.with_db do
      Punch::Spec.db.write do |db|
        Punch::Roles.assign(db, RolesSpec.user(3), RolesSpec::Roles::Auditor)
        Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1), expires_at: Time.utc - 1.second)
      end
      Punch::Spec.db.read do |db|
        Punch::Roles.check(db, RolesSpec.user(3), RolesSpec::Docs::Show, on: RolesSpec.team(2)).should eq(Punch::Policy::Decision::Allow)
        Punch::Roles.check(db, RolesSpec.user(3), RolesSpec::Docs::Update, on: RolesSpec.team(2)).should eq(Punch::Policy::Decision::Forbid)
        Punch::Roles.check(db, RolesSpec.user(3), RolesSpec::Docs::Show).should eq(Punch::Policy::Decision::Allow)
        Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Show, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::NotFound)
        Punch::Roles.holders(db, RolesSpec::Roles::Viewer, on: RolesSpec.team(1)).should eq(0)
      end
    end
  end

  it "reads a user's assignments once per transaction, and again after a change" do
    RolesSpec.with_db do
      RolesSpec.staff
      trace = Punch::Spec.trace do
        Punch::Spec.db.write do |db|
          3.times { Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Show, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Allow) }
          Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Update, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Forbid)
          Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Editor, on: RolesSpec.team(1))
          Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Update, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::Allow)
          Punch::Roles.revoke_all(db, on: RolesSpec.team(1))
          Punch::Roles.check(db, RolesSpec.user(2), RolesSpec::Docs::Show, on: RolesSpec.team(1)).should eq(Punch::Policy::Decision::NotFound)
        end
      end
      trace.spans.count(&.name.==("Punch::Roles.held")).should eq(3)
    end
  end

  it "tells a role policy which operation asks, and records the roles that decided" do
    RolesSpec.with_db do
      RolesSpec.staff
      viewer = RolesSpec.client(2)
      shown = viewer.get(RolesSpec::Docs::Show.path(doc_id: RolesSpec.doc(1)))
      shown.status.should eq(HTTP::Status::OK)
      shown.trace.root["punch.roles"].should eq("roles_spec.roles.viewer")
      refused = viewer.patch(RolesSpec::Docs::Update.path(doc_id: RolesSpec.doc(1)), json: {title: "Mine"})
      refused.status.should eq(HTTP::Status::FORBIDDEN)
      refused.trace.root["punch.authz"].should eq("forbid")
      RolesSpec.client(1).patch(RolesSpec::Docs::Update.path(doc_id: RolesSpec.doc(1)), json: {title: "Ours"}).status.should eq(HTTP::Status::OK)
      RolesSpec.client(3).get(RolesSpec::Docs::Show.path(doc_id: RolesSpec.doc(1))).status.should eq(HTTP::Status::NOT_FOUND)
      viewer.get(RolesSpec::Docs::Show.path(doc_id: RolesSpec.doc(3))).trace.root["punch.roles"].should eq("none")
    end
  end

  it "shows a viewer the page without the form a role refuses, with 403 behind it" do
    RolesSpec.with_db do
      RolesSpec.staff
      page = RolesSpec.client(2).visit(RolesSpec::Docs::ShowPage.href(doc_id: RolesSpec.doc(1)))
      page.status.should eq(HTTP::Status::OK)
      page.html.find("form").should be_empty
      RolesSpec.client(1).visit(RolesSpec::Docs::ShowPage.href(doc_id: RolesSpec.doc(1))).html.find("form").size.should eq(1)
      submitted = RolesSpec.client(2).submit(RolesSpec::Docs::Update.action(doc_id: RolesSpec.doc(1)), {title: "Mine"})
      submitted.status.should eq(HTTP::Status::FORBIDDEN)
    end
  end

  it "lists only what the roles permit, with full pages" do
    RolesSpec.with_db do
      RolesSpec.staff
      RolesSpec.client(2).get(RolesSpec::Docs::Index.path, query: {limit: "2"}).json["titles"].as_a.map(&.as_s).should eq(["Plan", "Budget"])
      RolesSpec.client(2).get(RolesSpec::Docs::Index.path, query: {limit: "9"}).json["titles"].as_a.size.should eq(3)
      RolesSpec.client(3).get(RolesSpec::Docs::Index.path, query: {limit: "9"}).json["titles"].as_a.should be_empty
      Punch::Spec.db.write { |db| Punch::Roles.assign(db, RolesSpec.user(3), RolesSpec::Roles::Auditor) }
      RolesSpec.client(3).get(RolesSpec::Docs::Index.path, query: {limit: "9"}).json["titles"].as_a.size.should eq(4)
    end
  end

  it "publishes what changed as events" do
    RolesSpec.with_db do
      Punch::Spec.db.write do |db|
        assignment = Punch::Roles.assign(db, RolesSpec.user(2), RolesSpec::Roles::Viewer, on: RolesSpec.team(1), assigned_by: RolesSpec.user(1))
        assigned = Punch::Roles::Assigned.new(assignment)
        assigned.role.should eq("roles_spec.roles.viewer")
        assigned.resource_id.should eq(1)
        assigned.assigned_by.should eq(1)
        Punch::Roles::Revoked.new(assignment, RolesSpec.user(1)).revoked_by.should eq(1)
        Punch::Roles::Assigned.from_json(assigned.to_json).resource_type.should eq("roles_spec.teams")
      end
    end
  end

  it "says which tables and the view a database lacks" do
    Punch::Spec.database do |database|
      Punch::Roles::Schema.problems(database).should eq([
        "table punch_role_assignments is missing; add it with a migration (lib/punch/docs/authorization.md)",
        "table punch_role_operations is missing; add it with a migration (lib/punch/docs/authorization.md)",
        "view punch_permissions is missing (lib/punch/docs/authorization.md)",
      ])
    end
  end
end
