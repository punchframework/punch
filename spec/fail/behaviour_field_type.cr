require "../../src/punch"

# A field of the wrong type does not satisfy a behaviour module either.
module Due
  abstract def due_at : Time?
end

module Queries::Page
  record Row, id : Int64, due_at : String do
    include Due
  end
end
