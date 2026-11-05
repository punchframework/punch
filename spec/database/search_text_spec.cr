require "../spec_helper"

private NAMES = ["50% off", "500 off", "a_b", "axb", %q(back\slash), "backXslash", %(say "hi"), "plain"]

private def like(db : Punch::Database, text : String) : Array(String)
  db.read do |reader|
    reader.query_all(%q(SELECT name FROM t WHERE name LIKE '%' || ? || '%' ESCAPE '\' ORDER BY name), text, &.read(String))
  end
end

private def match(db : Punch::Database, query : String) : Array(String)
  db.read do |reader|
    reader.query_all("SELECT name FROM docs WHERE docs MATCH ? ORDER BY name", query, &.read(String))
  end
end

describe "Punch::Database.escape_like" do
  it "puts a backslash before backslash, percent, and underscore only" do
    Punch::Database.escape_like(%q(50%_a\b)).should eq(%q(50\%\_a\\b))
    Punch::Database.escape_like("plain ä").should eq("plain ä")
  end

  it "makes the text match itself in a LIKE pattern built around it" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE t (name TEXT NOT NULL) STRICT")
        NAMES.each { |name| writer.exec("INSERT INTO t (name) VALUES (?)", name) }
      end
      like(db, "%").should eq(NAMES.sort)
      like(db, Punch::Database.escape_like("%")).should eq(["50% off"])
      like(db, Punch::Database.escape_like("_")).should eq(["a_b"])
      like(db, Punch::Database.escape_like("\\")).should eq([%q(back\slash)])
      like(db, Punch::Database.escape_like("0% o")).should eq(["50% off"])
      like(db, Punch::Database.escape_like("'; DROP TABLE t; --")).should be_empty
      like(db, "").size.should eq(NAMES.size)
    end
  end
end

describe "Punch::Database.fts_phrase" do
  it "quotes the text as one phrase, doubling the quotes inside" do
    Punch::Database.fts_phrase(%(say "hi" OR x)).should eq(%("say ""hi"" OR x"))
  end

  it "makes search syntax in the text plain words" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE VIRTUAL TABLE docs USING fts5(name)")
        ["red OR blue", "red", "blue", "NOT green", "star*", "stars"].each { |name| writer.exec("INSERT INTO docs (name) VALUES (?)", name) }
      end
      match(db, "red OR blue").should eq(["blue", "red", "red OR blue"])
      match(db, Punch::Database.fts_phrase("red OR blue")).should eq(["red OR blue"])
      match(db, Punch::Database.fts_phrase("star*")).should eq(["star*"])
      match(db, Punch::Database.fts_phrase("NOT green")).should eq(["NOT green"])
      match(db, Punch::Database.fts_phrase("a \"b) OR (c")).should be_empty
    end
  end
end

describe Punch::LikeText do
  it "matches the text as typed, whatever it holds, and binds it escaped" do
    text = Punch::LikeText.parse(%q(50%_a\b)).as(Punch::LikeText)
    text.value.should eq(%q(50%_a\b))
    text.bound.should eq(%q(50\%\_a\\b))
    Punch::Stored.dump(text).should eq(%q(50\%\_a\\b))
    text.to_json.should eq(%q("50%_a\\b"))
  end

  it "has an explicit opt-out for wildcards on purpose" do
    pattern = Punch::LikeText.pattern("50%")
    pattern.bound.should eq("50%")
    pattern.should_not eq(Punch::LikeText.parse("50%"))
    Punch::Stored.dump(pattern).should eq("50%")
  end

  it "reads from a request" do
    Punch::Input::Read.string(Punch::LikeText, "a%").should eq(Punch::LikeText.parse("a%"))
  end
end

describe Punch::FtsPhrase do
  it "binds one quoted phrase unless it is syntax on purpose" do
    phrase = Punch::FtsPhrase.parse(%(say "hi" OR x)).as(Punch::FtsPhrase)
    phrase.value.should eq(%(say "hi" OR x))
    Punch::Stored.dump(phrase).should eq(%("say ""hi"" OR x"))
    Punch::Stored.dump(Punch::FtsPhrase.syntax("red OR blue")).should eq("red OR blue")
  end

  it "refuses control characters, on which FTS5 fails every match" do
    Punch::FtsPhrase.parse("tea\0").should be_a(Punch::Invalid)
    Punch::FtsPhrase.parse("tea\u0007").as(Punch::Invalid).code.should eq("invalid_characters")
  end
end
