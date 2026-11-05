require "../../src/punch"

# A typed ID is stored as INTEGER; a TEXT column cannot load into it.
struct NoteID < Punch::TypedID
end

Punch::Stored.load(NoteID, "7", "notes", "id", nil)
