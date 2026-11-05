require "../../src/punch"

# A blind index hashes an encrypted column of its table.
module Notes
end

Punch.table "notes", Notes, body: Punch::NonEmptyString, body_index: Punch::BlindIndex.of(:body)
