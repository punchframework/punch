require "../../src/punch"

Punch::Auth::Password.parse("hunter2hunter2").as(Punch::Auth::Password).to_json
