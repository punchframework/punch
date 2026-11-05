require "../spec_helper"
require "../support/app_fixture"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

private def edit(& : String -> String) : Nil
  File.write("src/mailer.cr", yield File.read("src/mailer.cr"))
end

private def lock : JSON::Any
  JSON.parse(File.read("payloads.lock.json"))
end

describe "punch jobs:lock" do
  it "records payloads, takes compatible changes and new versions, and refuses breaking ones" do
    AppFixture.copy("spec/jobs/fixture") do
      run = punch("jobs:lock")
      {run.code, run.stderr}.should eq({0, ""})
      run.stdout.lines.first.should eq("written   payloads.lock.json (14 job types, 14 payloads)")
      run.stdout.should contain("Mailer::SignedUp: new payload, version 1")
      lock["types"].as_h.keys.should eq(["Mailer::Greet(Mailer::SignedUp)", "Mailer::Welcome", "Punch::Auth::Purge", "Punch::Backup::Verify", "Punch::Caches::Trim", "Punch::Database::Audit::Run", "Punch::Database::Encryption::Run", "Punch::Database::Upgrade::Run", "Punch::IdempotencyKeys::Purge", "Punch::Job::Queue::Purge", "Punch::Ops::Notify", "Punch::Ops::Purge", "Punch::Webhook::Process", "Punch::Webhook::Purge"])
      lock["types"]["Mailer::Greet(Mailer::SignedUp)"].should eq("Mailer::SignedUp")
      punch("jobs:lock", "--check").code.should eq(0)

      # Additive: a nilable field and a defaulted one. Stale until written.
      edit(&.sub("    getter user_id : Int64\n\n    def initialize(@user_id)\n    end\n\n    def perform",
        "    getter user_id : Int64\n    getter note : String?\n    getter days : Int32 = 3\n\n    def initialize(@user_id)\n    end\n\n    def perform"))
      stale = punch("jobs:lock", "--check", "--json")
      stale.code.should eq(1)
      error = JSON.parse(stale.stdout)["error"]
      error["code"].should eq("stale_payload_lock")
      error["message"].as_s.should contain("(Mailer::Welcome: compatible change)")
      punch("jobs:lock").stdout.should contain("Mailer::Welcome: compatible change")
      welcome = lock["payloads"]["Mailer::Welcome"]["schema"]["$defs"]["Mailer.Welcome"]
      welcome["required"].should eq(JSON.parse(%(["user_id"])))
      welcome["properties"]["note"].should eq(JSON.parse(%({"type": ["string", "null"]})))

      # A new required field breaks payloads already waiting.
      edit(&.sub("    getter days : Int32 = 3\n\n    def initialize(@user_id)\n",
        "    getter days : Int32 = 3\n    getter locale : String\n\n    def initialize(@user_id, @locale)\n"))
      before = File.read("payloads.lock.json")
      breaking = punch("jobs:lock", "--json")
      breaking.code.should eq(1)
      error = JSON.parse(breaking.stdout)["error"]
      error["code"].should eq("breaking_payload_change")
      error["message"].as_s.should contain("Mailer::Welcome.locale is new and required: payloads written before lack it")
      error["message"].as_s.should contain("raise the payload version: @[Punch::Payloads::Version(N, from: {N - 1 => V1})]")
      File.read("payloads.lock.json").should eq(before)

      # The way out: version 2, with version 1 kept as a frozen type.
      edit(&.sub("  struct Welcome\n", "  @[Punch::Payloads::Version(2, from: {1 => V1})]\n  struct Welcome\n")
        .sub("    def perform(job : Punch::Job::Context) : Punch::Job::Result\n    end\n  end\n\n  struct SignedUp",
          "    def perform(job : Punch::Job::Context) : Punch::Job::Result\n    end\n\n" \
          "    struct V1\n      include Punch::Payloads::Frozen\n\n      getter user_id : Int64\n      getter note : String?\n      getter days : Int32 = 3\n\n" \
          "      def upgrade : Welcome\n        Welcome.new(user_id, \"en\")\n      end\n    end\n  end\n\n  struct SignedUp"))
      bumped = punch("jobs:lock")
      {bumped.code, bumped.stderr}.should eq({0, ""})
      bumped.stdout.should contain("Mailer::Welcome: version 1 to 2")
      lock["payloads"]["Mailer::Welcome"]["version"].should eq(2)
      lock["payloads"]["Mailer::Welcome"]["frozen"]["1"]["$defs"]["Mailer.Welcome.V1"]["required"].should eq(JSON.parse(%(["user_id"])))

      # A frozen type never changes.
      edit(&.sub("      getter days : Int32 = 3\n\n      def upgrade", "      getter days : Int64 = 3\n\n      def upgrade"))
      punch("jobs:lock").stderr.should contain("Mailer::Welcome: the frozen type of version 1 changed")
      edit(&.sub("      getter days : Int64 = 3\n\n      def upgrade", "      getter days : Int32 = 3\n\n      def upgrade"))

      # A removed subscriber leaves jobs nothing runs: acknowledged by hand.
      edit(&.sub(/  @\[Punch::Subscriber::Delivery\(:deferred\)\].*?\n  end\n/m, ""))
      gone = punch("jobs:lock")
      gone.code.should eq(1)
      gone.stderr.should contain("Mailer::Greet(Mailer::SignedUp) is gone, but jobs of it may still wait in queue.db")
      dropped = punch("jobs:lock", "--drop", "Mailer::Greet(Mailer::SignedUp)")
      {dropped.code, dropped.stderr}.should eq({0, ""})
      dropped.stdout.should contain("Mailer::Greet(Mailer::SignedUp): removed")
      lock["payloads"].as_h.has_key?("Mailer::SignedUp").should be_false

      # Whole rows do not go into payloads.
      edit(&.sub("  struct SignedUp\n", "  struct Row\n    include JSON::Serializable\n\n    getter id : Int64\n\n" \
                                        "    def self.read(row : Punch::Database::Row) : self\n      from_json(%({\"id\": 1}))\n    end\n  end\n\n  struct SignedUp\n")
        .sub("    getter note : String?\n    getter days : Int32 = 3\n    getter locale", "    getter note : String?\n    getter days : Int32 = 3\n    getter user : Row?\n    getter locale"))
      row = punch("jobs:lock")
      row.code.should eq(1)
      row.stderr.should contain("Mailer::Welcome#user holds Mailer::Row, a whole row, in a stored payload")
    end
  end
end
