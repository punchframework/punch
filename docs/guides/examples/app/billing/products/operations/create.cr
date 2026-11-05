module Billing::Products
  # A product as the API shows it once it is in the catalogue.
  @[Punch::Status(201)]
  record Created,
    id : ID,
    name : Punch::NonEmptyString,
    pricing : Pricing do
    include JSON::Serializable
  end

  # One price of a new product.
  struct PriceInput
    include Punch::Input

    getter currency : Punch::Currency
    getter amount : Punch::Money
  end

  # Adds a product with its unit and its prices, one per currency.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter name : Punch::NonEmptyString
      getter unit : Punch::NonEmptyString
      getter prices : Array(PriceInput)
    end

    alias Output = Created | NameTaken | Punch::Rejection

    def call(input : Input, db : Punch::Writer, _actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      prices = input.prices.to_h { |price| {price.currency, price.amount} }
      pricing = Pricing.build(unit: input.unit, prices: prices)
      # More currencies than the declared bound: `too_many`, at `prices`.
      return Punch::Rejection.new(Punch::Rejection::Path{"prices"}, pricing) if pricing.is_a?(Punch::Invalid)

      case product = Table.insert(db, name: input.name, pricing: pricing)
      in Record    then Created.new(product.id, product.name, product.pricing)
      in NameTaken then product
      end
    end
  end
end
