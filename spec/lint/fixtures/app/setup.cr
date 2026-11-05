# Punch/SetupFile: the place for them.
Punch.assets "assets"
Punch::Auth.config = Punch::Auth::Config.new(token_prefix: "inv")
Punch::Ops::Console.mount Invoicing::Actor
Punch.table "invoices", Billing::Invoices # expect
