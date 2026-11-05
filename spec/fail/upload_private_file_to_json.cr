require "../../src/punch"

# A private file's name is a secret, so a file cannot go into an answer whole.
def answer(file : Punch::Upload::PrivateFile)
  file.to_json
end

answer(Punch::Upload::PrivateFile.build(
  key: Punch::Upload::Key.parse("a.b/#{"a" * 26}").as(Punch::Upload::Key),
  filename: Punch::Secret.new(Punch::Upload::Filename.default("application/pdf")),
  size: 1_i64, content_type: "application/pdf").as(Punch::Upload::PrivateFile))
