# An order: code does not belong in its outline.
module Shop::Orders
  LIMIT = 10 # expect

  # A cache is not a value the domain names.
  CACHE = Hash(String, Int32).new # expect

  def self.limit # expect
    LIMIT
  end
end
