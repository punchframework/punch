require "../../src/punch"

# An encrypted column holds a primitive, Time, Bool, or a stored type.
module Notes
end

Punch.table "notes", Notes, body: Punch::Encrypted(Array(String))
