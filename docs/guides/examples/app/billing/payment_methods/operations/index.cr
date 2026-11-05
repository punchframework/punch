module Billing::PaymentMethods
  # A customer's payment methods, each with its `kind`.
  @[Punch::Status(200)]
  record Listed,
    methods : Array(Method) do
    include JSON::Serializable
  end

  # The payment methods of the customer with *customer_email*.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      getter customer_email : Punch::Email
    end

    alias Output = Listed

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      Listed.new(Queries.of_customer(db, customer_email: input.customer_email).map(&.method))
    end
  end
end
