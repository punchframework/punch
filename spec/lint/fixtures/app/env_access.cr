# Fixture for Punch/EnvAccess: ENV in hand-written app code.
module Shop
  API_KEY = ENV["STRIPE_KEY"] # expect

  def self.region : String
    ::ENV["REGION"]? || "eu" # expect
  end

  def self.zone : String
    String.new(LibC.getenv("ZONE")) # expect
  end

  def self.key : String
    Shop::Credentials.current.stripe.secret_key.unwrap
  end
end
