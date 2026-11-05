require "../../src/punch"

# A behaviour module names the fields it needs; a query row without one of
# them does not compile. The row is shaped like a generated one.
module Due
  abstract def due_at : Time?

  def overdue?(now : Time) : Bool
    (due = due_at) ? now > due : false
  end
end

module Queries::Page
  record Row, id : Int64, sent_at : Time? do
    include Due
  end
end
