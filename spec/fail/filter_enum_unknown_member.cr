require "../../src/punch"

# An enum filter field's clauses become a `case … in` over the enum, shaped
# here like a generated method; a clause for a name that is not a member
# does not compile.
enum State
  Draft
  Sent
  Paid
end

module Queries::InState
  WHEN_STATE_DRAFT = "AND status = 'draft'"
  WHEN_STATE_SENT  = "AND status = 'sent'"

  def self.sql(state : State?) : String
    String.build do |io|
      state.try do |value|
        case value
        in .draft? then io << WHEN_STATE_DRAFT
        in .sent?  then io << WHEN_STATE_SENT
        in .paid?  then io << WHEN_STATE_SENT
        in .payed? then io << WHEN_STATE_SENT
        end
      end
    end
  end
end

Queries::InState.sql(State::Draft.as(State?))
