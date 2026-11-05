require "../../src/punch"

# A column can only map to a domain primitive, Time, or Bool.
class Plain
end

Punch.table "notes", Notes,
  body: Plain
