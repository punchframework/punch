require "../../src/punch"

module Plans
  struct ID < Punch::TypedID
    public_id "pln"
  end

  module Table
    Punch::TypedID.reusing_rowids ::Plans::ID, "plans"
  end
end
