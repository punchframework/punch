require "../../src/punch"

# Stored.dump is for columns that are not encrypted: a private file's name
# would be written in the clear.
def dump(file : Punch::Upload::PrivateFile)
  Punch::Stored.dump(file)
end

dump(Punch::Upload::PrivateFile.build(
  key: Punch::Upload::Key.parse("a.b/#{"a" * 26}").as(Punch::Upload::Key),
  filename: Punch::Secret.new(Punch::Upload::Filename.default("application/pdf")),
  size: 1_i64, content_type: "application/pdf").as(Punch::Upload::PrivateFile))
