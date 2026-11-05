require "../spec_helper"
require "../../src/punch/jobs/lock"

module LockSpec
  # A payload schema as the derivation writes it: one object under $defs.
  def self.schema(properties : String, required : Array(String), defs : String = "") : JSON::Any
    JSON.parse(%({"$ref": "#/$defs/P", "$defs": {"P": {"type": "object", "properties": {#{properties}}, "required": #{required.to_json}}#{defs}}}))
  end

  def self.lock(schema : JSON::Any, version : Int32 = 1, frozen : Hash(String, JSON::Any)? = nil, type : String = "App::Remind") : JSON::Any
    payload = {"version" => JSON::Any.new(version.to_i64), "schema" => schema}
    payload["frozen"] = JSON::Any.new(frozen) if frozen
    JSON.parse({types: {type => "App::Remind"}, payloads: {"App::Remind" => payload}}.to_json)
  end

  def self.problems(old : JSON::Any, new : JSON::Any) : Array(String)
    Punch::Payloads::Lock.new(lock(old), lock(new)).problems
  end

  ID       = %("id": {"type": "integer", "format": "int64", "minimum": 1})
  NOTE     = %("note": {"type": ["string", "null"]})
  DAYS     = %("days": {"type": "integer", "format": "int32"})
  BASE     = schema(ID, ["id"])
  WITH_ALL = schema("#{ID}, #{NOTE}, #{DAYS}", ["id"])
end

describe Punch::Payloads::Lock do
  it "accepts fields added as nilable or with a default, and optional fields removed" do
    comparison = Punch::Payloads::Lock.new(LockSpec.lock(LockSpec::BASE), LockSpec.lock(LockSpec::WITH_ALL))
    comparison.problems.should be_empty
    comparison.notes.should eq(["App::Remind: compatible change"])
    LockSpec.problems(LockSpec::WITH_ALL, LockSpec::BASE).should be_empty
    Punch::Payloads::Lock.new(LockSpec.lock(LockSpec::BASE), LockSpec.lock(LockSpec::BASE)).notes.should be_empty
  end

  it "rejects what one side of a deploy cannot read" do
    LockSpec.problems(LockSpec::BASE, LockSpec.schema("#{LockSpec::ID}, #{LockSpec::DAYS}", %w[id days])).should eq([
      "App::Remind.days is new and required: payloads written before lack it",
    ])
    LockSpec.problems(LockSpec.schema(LockSpec::DAYS, %w[days]), LockSpec.schema(LockSpec::ID, %w[id])).should eq([
      "App::Remind.id is new and required: payloads written before lack it",
      "App::Remind.days was removed: binaries before this one require it",
    ])
    # Nilable to required, and back.
    nilable = LockSpec.schema(%("id": {"type": ["integer", "null"], "format": "int64", "minimum": 1}), [] of String)
    LockSpec.problems(nilable, LockSpec::BASE).should eq(["App::Remind.id became required: payloads written before may lack it"])
    LockSpec.problems(LockSpec::BASE, nilable).should eq(["App::Remind.id may now be missing: binaries before this one require it"])
    # A defaulted field becoming required is fine: it was always written.
    LockSpec.problems(LockSpec.schema(LockSpec::DAYS, [] of String), LockSpec.schema(LockSpec::DAYS, %w[days])).should be_empty
  end

  it "rejects a changed type, down to enum members, through references and into nested objects" do
    LockSpec.problems(LockSpec::BASE, LockSpec.schema(%("id": {"type": "integer", "format": "int32"}), %w[id])).should eq([
      %(App::Remind.id changed from {"type":"integer","format":"int64","minimum":1} to {"type":"integer","format":"int32"}),
    ])
    channel = ->(members : String) { LockSpec.schema(%("channel": {"$ref": "#/$defs/C"}), %w[channel], %(, "C": {"type": "string", "enum": [#{members}]})) }
    LockSpec.problems(channel.call(%("email")), channel.call(%("email", "sms"))).should eq([
      %(App::Remind.channel changed from {"type":"string","enum":["email"]} to {"type":"string","enum":["email","sms"]}),
    ])
    # A renamed type with the same shape is the same payload.
    renamed = LockSpec.schema(%("channel": {"$ref": "#/$defs/D"}), %w[channel], %(, "D": {"type": "string", "enum": ["email"]}))
    LockSpec.problems(channel.call(%("email")), renamed).should be_empty

    nested = ->(fields : String, required : String) do
      LockSpec.schema(%("lines": {"type": "array", "items": {"$ref": "#/$defs/L"}}), %w[lines],
        %(, "L": {"type": "object", "properties": {#{fields}}, "required": [#{required}]}))
    end
    LockSpec.problems(nested.call(LockSpec::ID, %("id")), nested.call("#{LockSpec::ID}, #{LockSpec::NOTE}", %("id"))).should be_empty
    LockSpec.problems(nested.call(LockSpec::ID, %("id")), nested.call("#{LockSpec::ID}, #{LockSpec::DAYS}", %("id", "days"))).should eq([
      "App::Remind.lines[].days is new and required: payloads written before lack it",
    ])
  end

  it "takes a new version when the frozen type reads what the old version wrote" do
    days = LockSpec.schema("#{LockSpec::ID}, #{LockSpec::DAYS}", %w[id days])
    bumped = LockSpec.lock(days, 2, {"1" => LockSpec::BASE})
    comparison = Punch::Payloads::Lock.new(LockSpec.lock(LockSpec::BASE), bumped)
    {comparison.problems, comparison.notes}.should eq({[] of String, ["App::Remind: version 1 to 2"]})

    Punch::Payloads::Lock.new(LockSpec.lock(LockSpec::BASE), LockSpec.lock(days, 2)).problems.should eq([
      "App::Remind: version 1 payloads may still be waiting, but nothing reads them now: keep their shape as a frozen type, from: {1 => V1} (lib/punch/docs/jobs.md)",
    ])
    wrong = LockSpec.lock(days, 2, {"1" => days})
    Punch::Payloads::Lock.new(LockSpec.lock(LockSpec::BASE), wrong).problems.should eq([
      "App::Remind version 1 (frozen type).days is new and required: payloads written before lack it",
    ])
    # Frozen means frozen; deleting one is allowed.
    changed = LockSpec.lock(days, 2, {"1" => LockSpec::WITH_ALL})
    Punch::Payloads::Lock.new(bumped, changed).problems.should eq([
      "App::Remind: the frozen type of version 1 changed; a frozen type keeps the shape its version was written with",
    ])
    Punch::Payloads::Lock.new(bumped, LockSpec.lock(days, 2)).notes.should eq([
      "App::Remind: the frozen type of version 1 was removed; payloads of that version are parked",
    ])
    Punch::Payloads::Lock.new(bumped, LockSpec.lock(LockSpec::BASE)).problems.should eq([
      "App::Remind: the payload version went down from 2 to 1; jobs of version 2 may be waiting",
    ])
  end

  it "refuses a removed job type until it is acknowledged" do
    old = LockSpec.lock(LockSpec::BASE)
    gone = JSON.parse(%({"types": {}, "payloads": {}}))
    problems = Punch::Payloads::Lock.new(old, gone).problems
    problems.size.should eq(1)
    problems[0].should start_with("App::Remind is gone, but jobs of it may still wait in queue.db")
    problems[0].should end_with("punch jobs:lock --drop 'App::Remind'")
    Punch::Payloads::Lock.new(old, gone, ["App::Remind"]).notes.should eq(["App::Remind: removed"])
    Punch::Payloads::Lock.new(old, gone, removals: true).ok?.should be_true
    Punch::Payloads::Lock.new(nil, old).notes.should eq(["App::Remind: new payload, version 1"])
  end
end

module LockSpec
  ROW_ID = %({"type": "integer", "format": "int64"})

  # A lock whose App::Import runs in *steps*: each a name and, when given,
  # its cursor's schema.
  def self.steps(steps : Array({String, String?})) : JSON::Any
    entries = steps.map do |name, cursor|
      cursor ? %({"name": "#{name}", "cursor": #{cursor}}) : %({"name": "#{name}"})
    end
    JSON.parse(%({"types": {"App::Import": "App::Import"}, "payloads": {"App::Import": {"version": 1, "schema": #{BASE.to_json}, "steps": [#{entries.join(", ")}]}}}))
  end
end

describe "Punch::Payloads::Lock, steps" do
  it "notes new steps, and which runs skip a step put before others" do
    old = LockSpec.steps([{"check", nil}, {"copy", LockSpec::ROW_ID}])
    comparison = Punch::Payloads::Lock.new(old, LockSpec.steps([{"check", nil}, {"scan", nil}, {"copy", LockSpec::ROW_ID}, {"report", nil}]))
    comparison.problems.should be_empty
    comparison.notes.should eq([
      "App::Import#scan: new step before copy; a run stopped at copy or after it does not run it",
      "App::Import#report: new step",
    ])
  end

  it "rejects a removed step until it is dropped, and says how without the payload advice" do
    old = LockSpec.steps([{"check", nil}, {"copy", LockSpec::ROW_ID}])
    new = LockSpec.steps([{"check", nil}, {"copy_rows", LockSpec::ROW_ID}])
    comparison = Punch::Payloads::Lock.new(old, new)
    comparison.problems.size.should eq(1)
    comparison.problems.first.should start_with("App::Import#copy is gone, but a run may be stopped at it")
    comparison.problems.first.should end_with("punch jobs:lock --drop 'App::Import#copy'")
    comparison.ways_out.should eq("")
    Punch::Payloads::Lock.new(old, new, ["App::Import#copy"]).problems.should be_empty
  end

  it "compares a cursor's schema by the payload rules" do
    old = LockSpec.steps([{"copy", LockSpec::ROW_ID}])
    problems = Punch::Payloads::Lock.new(old, LockSpec.steps([{"copy", %({"type": "string"})}])).problems
    problems.should eq([%(App::Import#copy cursor changed from {"type":"integer","format":"int64"} to {"type":"string"}; ) +
                        "a run stopped at the step could not read its saved cursor. Keep the cursor's type, or give the step a new name (the old one then needs --drop)"])
    Punch::Payloads::Lock.new(old, LockSpec.steps([{"copy", nil}])).notes.should eq(["App::Import#copy cursor removed; a run stopped part-way through the step starts it over"])
  end
end

describe "the derived lock of a job with steps" do
  it "records each step in order with its cursor's schema" do
    steps = StepsSpec::Walk.punch_steps_lock
    steps.as_a.map(&.["name"].as_s).should eq(["walk"])
    cursor = steps[0]["cursor"]
    cursor["$ref"].as_s.should end_with("Position")
    StepsSpec::Copy.punch_steps_lock.to_json.should eq(
      %([{"name":"count"},{"name":"copy_rows","cursor":{"type":"integer","format":"int64"}},{"name":"report"}]))
  end
end
