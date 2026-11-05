require "../../src/punch"

# A parameter that feeds a `LIKE … ESCAPE '\'` is a `Punch::LikeText`
# (shaped here like a generated method), so a plain `String`, whose `%`
# and `_` would be wildcards, does not compile. `LikeText.pattern` is the
# explicit opt-out.
module Queries
  def self.customers_matching(db : Punch::Reader, *, q : Punch::LikeText) : Nil
  end
end

Queries.customers_matching(Punch::Reader.allocate, q: "50%")
