module Billing::Customers
  # A sent or paid invoice changes what its customer owes, so the cached
  # statement is forgotten once the change is committed; the next request
  # computes it again. Without this, the statement would be up to a minute
  # old. Punch writes the `call` (`punch events` shows the store).
  @[Punch::Subscriber::Forget(STATEMENTS, key: customer_id)]
  struct ForgetStatement
    include Punch::Subscriber(BalanceChanged)
  end
end
