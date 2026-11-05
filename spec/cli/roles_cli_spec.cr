require "../spec_helper"
require "../auth/roles_spec"
require "../auth/authorization_spec"
require "../../src/punch/cli"

private def run(*args : String) : {Int32, String, String}
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::APP_COMMANDS)
  {code, stdout.to_s, stderr.to_s}
end

private def json(*args : String) : JSON::Any
  JSON.parse(run(*args, "--json")[1])
end

# `authz:explain` as the derivation build runs it, which has the
# explainers: its text, or its JSON document.
private def explain(*args : String) : String
  outcome = Punch::CLI::Commands::AuthzExplain.new(Punch::CLI::APP_COMMANDS).explain(args.to_a, Punch::Authorization.explainers)
  outcome.is_a?(Punch::CLI::Report) ? String.build { |io| outcome.to_text(io) } : "#{outcome.code}: #{outcome.message}"
end

private def explain_json(*args : String) : JSON::Any
  case outcome = Punch::CLI::Commands::AuthzExplain.new(Punch::CLI::APP_COMMANDS).explain(args.to_a, Punch::Authorization.explainers)
  in Punch::CLI::Report  then JSON.parse(outcome.to_json)
  in Punch::CLI::Failure then JSON.parse({error: {code: outcome.code, message: outcome.message}}.to_json)
  end
end

# A storage directory whose primary.db has the roles spec's tables, docs,
# and staff (Ada edits team 1, Grace views it with an expired auditor
# role), as PUNCH_STORAGE for the block.
private def with_storage(&)
  storage = File.tempname("punch-roles-cli")
  Dir.mkdir(storage)
  database = Punch::Database.open(File.join(storage, "primary.db"))
  Punch::Migrations::Schema.load(database, AuthSchema::SQL + Punch::Roles::Schema.sql + RolesSpec::SQL, "roles")
  database.write do |db|
    db.exec("INSERT INTO users (id, name) VALUES (1, 'Ada'), (2, 'Grace'), (3, 'Edsger')")
    Punch::Roles.assign(db, 1_i64, RolesSpec::Roles::Editor, on: RolesSpec.team(1))
    Punch::Roles.assign(db, 2_i64, RolesSpec::Roles::Viewer, on: RolesSpec.team(1), assigned_by: 1_i64)
    Punch::Roles.assign(db, 2_i64, RolesSpec::Roles::Auditor, expires_at: Time.utc - 1.hour)
  end
  database.close
  ENV["PUNCH_STORAGE"] = storage
  yield storage
ensure
  ENV.delete("PUNCH_STORAGE")
  FileUtils.rm_rf(storage) if storage
end

describe "punch roles" do
  it "lists the roles with their operations" do
    code, stdout, _ = run("roles")
    code.should eq(0)
    stdout.should contain(<<-TEXT)
      roles_spec.roles.editor (on roles_spec.teams)
        roles_spec.docs.index
        roles_spec.docs.show
        roles_spec.docs.show_page
        roles_spec.docs.update
      TEXT
    stdout.should contain("roles_spec.roles.auditor (global)\n")
    json("roles")["roles"].as_a.find! { |role| role["name"] == "roles_spec.roles.viewer" }["scope"].should eq("roles_spec.teams")
  end

  it "lists a user's assignments, expired ones marked" do
    with_storage do
      code, stdout, _ = run("roles", "--user", "2")
      code.should eq(0)
      lines = stdout.lines
      lines[0].should match(/roles_spec\.roles\.viewer on roles_spec\.teams 1  since .*  by user 1\z/)
      lines[1].should match(/roles_spec\.roles\.auditor  expired /)
      json("roles", "--user", "3")["assignments"].as_a.should be_empty
    end
  end
end

describe "punch authz:explain" do
  it "says a role forbids, which roles would permit, and what the user holds" do
    with_storage do
      explain("roles_spec.docs.update", "--user", "2", "doc_id=1").should eq(<<-TEXT)
        roles_spec.docs.update (RolesSpec::Docs::Update) for user 2 with doc_id=1
          policy:    RolesSpec::TeamRoles
          decision:  forbid (403 forbidden)
          roles:     roles_spec.roles.viewer
          permitted by: roles_spec.roles.editor
          user 2 holds:
            roles_spec.roles.viewer on roles_spec.teams 1
            roles_spec.roles.auditor (expired)

        TEXT
    end
  end

  it "allows by type name, hides where nothing is held, and rolls back" do
    with_storage do
      allowed = explain_json("RolesSpec::Docs::Update", "--user", "1", "doc_id=1")
      allowed["explanation"]["decision"].should eq("allow")
      allowed["explanation"]["roles"].should eq("roles_spec.roles.editor")
      hidden = explain_json("roles_spec.docs.show", "--user", "3", "doc_id=1")
      hidden["explanation"]["decision"].should eq("not_found")
      hidden["explanation"]["roles"].should eq("none")
      explain_json("roles_spec.docs.index", "--user", "3")["explanation"]["policy"].should eq("Punch::SignedIn")
    end
  end

  it "is only in the derivation build" do
    outcome = Punch::CLI::Commands::AuthzExplain.new(Punch::CLI::APP_COMMANDS).run(["roles_spec.docs.show", "--user", "1"])
    outcome.as(Punch::CLI::Failure).code.should eq("not_derivation_build")
  end

  it "refuses what it cannot run" do
    with_storage do
      explain_json("roles_spec.docs.update", "--user", "2")["error"]["message"].should eq("RolesSpec::Docs::Update needs the path parameter doc_id=RolesSpec::Docs::ID.")
      explain_json("roles_spec.docs.update", "--user", "2", "doc_id=x")["error"]["code"].should eq("cannot_explain")
      explain_json("roles_spec.docs.update", "--user", "2", "doc_id=1", "team=1")["error"]["message"].as_s.should contain("no path parameter team")
      explain_json("roles_spec.docs.update", "--user", "9", "doc_id=1")["explanation"]["decision"].should eq("not_found")
      explain_json("no.such.thing", "--user", "2")["error"]["code"].should eq("unknown_operation")
      explain_json("authorization_spec.notes.front_page", "--user", "2")["error"]["message"].as_s.should contain("it is public")
      explain_json("roles_spec.docs.update")["error"]["message"].as_s.should contain("needs --user ID")
    end
  end
end

describe "punch roles:assign and roles:revoke" do
  it "give and take a global role, by stored or type name, by ID or address" do
    with_storage do
      code, stdout, _ = run("roles:assign", "RolesSpec::Roles::Auditor", "--user", "3")
      code.should eq(0)
      stdout.should eq("User 3 now holds roles_spec.roles.auditor.\n")
      Punch::Database.open(File.join(ENV["PUNCH_STORAGE"], "primary.db")).tap do |database|
        database.write { |db| Punch::Auth::EmailIdentities.add(db, 3_i64, Punch::Email.parse("edsger@example.org").as(Punch::Email), verified_at: Time.utc) }
        database.close
      end
      json("roles:revoke", "roles_spec.roles.auditor", "--email", "edsger@example.org")["assignment"]["user_id"].should eq(3)
      json("roles:revoke", "roles_spec.roles.auditor", "--user", "3")["error"]["code"].should eq("not_held")
    end
  end

  it "refuses a role held on a resource, an unknown user, and wrong usage" do
    with_storage do
      json("roles:assign", "roles_spec.roles.editor", "--user", "1")["error"]["message"].as_s.should match(/is not a global role of this app\. Global roles: .*roles_spec\.roles\.auditor/)
      json("roles:assign", "roles_spec.roles.auditor", "--user", "99")["error"]["code"].should eq("unknown_user")
      json("roles:assign", "roles_spec.roles.auditor", "--email", "nobody@example.org")["error"]["code"].should eq("unknown_user")
      run("roles:assign", "roles_spec.roles.auditor")[0].should eq(2)
      run("roles:assign", "roles_spec.roles.auditor", "--user", "1", "--email", "a@example.org")[0].should eq(2)
    end
  end

  it "refuses an address its claimant has not verified" do
    with_storage do
      Punch::Database.open(File.join(ENV["PUNCH_STORAGE"], "primary.db")).tap do |database|
        database.write { |db| Punch::Auth::EmailIdentities.add(db, 3_i64, Punch::Email.parse("claimed@example.org").as(Punch::Email)) }
        database.close
      end
      error = json("roles:assign", "roles_spec.roles.auditor", "--email", "claimed@example.org")["error"]
      error["code"].should eq("unverified_email")
      error["message"].as_s.should contain("--user ID")
      json("roles:revoke", "roles_spec.roles.auditor", "--email", "claimed@example.org")["error"]["code"].should eq("unverified_email")
      json("roles:assign", "roles_spec.roles.auditor", "--user", "3")["assignment"]["user_id"].should eq(3)
    end
  end
end
