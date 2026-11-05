# Punch/SetupFile: app-wide declarations outside app/setup.cr.
Punch.assets "assets"                                             # expect
Punch::Auth.config = Punch::Auth::Config.new(token_prefix: "inv") # expect
Punch::Ops::Console.mount Invoicing::Actor                        # expect
Punch.table "invoices", Billing::Invoices                         # expect

module Invoicing
  Punch.translations Invoicing::Translations, default: "en" # expect

  def self.later
    Punch::Auth.config = Punch::Auth::Config.new
  end
end

Punch.asset("app.css")
