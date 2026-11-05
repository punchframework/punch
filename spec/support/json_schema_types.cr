# Types for the JSON Schema specs.
module JSONSchemaSpec
  enum Order
    NewestFirst
    Oldest
  end

  struct InvoiceID < Punch::TypedID
  end

  struct Line
    include Punch::Input

    getter description : Punch::NonEmptyString
    getter quantity : Float64
    getter unit_cents : Int64
  end

  struct Create
    include Punch::Input

    @[Punch::PathParam]
    getter invoice_id : InvoiceID

    getter number : Punch::Slug
    getter recipient : Punch::Email
    getter note : String?
    getter copies : Int32 = 1
    getter order : Order = Order::NewestFirst
    getter? urgent : Bool = false
    getter due : Time?
    getter lines : Array(Line)
    getter tags : Array(String)?
    getter label : String = "draft"
    getter rate : Float64 = 1.5
  end

  # Refers to itself through an array.
  struct Tree
    include Punch::Input

    getter name : String
    getter children : Array(Tree)?
  end

  struct Shown
    include JSON::Serializable

    getter id : InvoiceID
    getter email : Punch::Email
    @[JSON::Field(key: "total")]
    getter total_cents : Int64
    @[JSON::Field(ignore: true)]
    getter cache : String = ""
    getter sent_at : Time?
    @[JSON::Field(emit_null: true)]
    getter note : String?
    getter order : Order
    getter counts : Hash(String, Int32)
    getter value : String | Int64

    def initialize(@id, @email, @total_cents, @sent_at, @note, @order, @counts, @value)
    end
  end
end
