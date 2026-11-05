module Accounts::Roles
  # Runs the app: the ops console at /_punch. Given on the box with `punch roles:assign
  # Accounts::Roles::Operator --email ADDRESS`; `db/seeds.cr` gives it to
  # the development user.
  struct Operator
    include Punch::Role

    permits Punch::Ops::Console::Operations
  end
end
