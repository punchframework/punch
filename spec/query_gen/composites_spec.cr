require "../spec_helper"
require "./fixture/app/ledger/types"
require "./fixture/app/ledger/customers/record"
require "./fixture/app/ledger/composites.gen"
require "./fixture/app/ledger/geo"
require "./fixture/app/ledger/columns"
require "./fixture/app/ledger/records.gen"
require "./fixture/app/ledger/orders/columns"
require "./fixture/app/ledger/orders/records.gen"
require "./fixture/app/ledger/orders/billed_to"
require "./fixture/app/ledger/sites/columns"
require "./fixture/app/ledger/sites/records.gen"
require "./fixture/app/ledger/queries.gen"
require "../../src/punch/jobs/lock"

# Composites as `punch db:generate` writes them (docs/composites.md), run
# against the generator fixture's schema: groups of columns on sites,
# documents on orders.
module CompositesSpec
  SCHEMA = "#{__DIR__}/fixture/db/schema.sql"

  def self.text(value : String) : Punch::NonEmptyString
    Punch::NonEmptyString.parse(value).as(Punch::NonEmptyString)
  end

  def self.money(value : Int64) : Punch::Money
    Punch::Money.parse(value).as(Punch::Money)
  end

  def self.currency(value : String) : Punch::Currency
    Punch::Currency.parse(value).as(Punch::Currency)
  end

  def self.address(city : String = "Berlin", geo : Ledger::Geo? = nil) : Ledger::Address
    Ledger::Address.build(street: text("Main St 1"), city: text(city), geo: geo).as(Ledger::Address)
  end

  def self.line(description : String = "Work") : Ledger::Line
    Ledger::Line.build(description: text(description), quantity: 2.5, unit_price: money(300)).as(Ledger::Line)
  end

  def self.shipment(lines : Int32 = 1, payment : Ledger::Payment? = nil) : Ledger::Orders::Shipment
    Ledger::Orders::Shipment.build(address: address, lines: Array.new(lines) { line }, prices: {currency("EUR") => money(1250)}, payment: payment).as(Ledger::Orders::Shipment)
  end

  def self.card : Ledger::Card
    Ledger::Card.build(last4: text("4242"), brand: "visa").as(Ledger::Card)
  end

  def self.with_db(& : Punch::Database ->) : Nil
    previous = Punch::KeyRing.current?
    Punch::KeyRing.current = Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)])
    begin
      Punch::Spec.database(schema: SCHEMA) do |db|
        db.write { |writer| writer.exec("INSERT INTO accounts (id, name, created_at) VALUES (1, 'Acme', '2026-10-01T00:00:00Z')") }
        yield db
      end
    ensure
      previous.try { |ring| Punch::KeyRing.current = ring }
    end
  end

  ACME = Ledger::Accounts::ID.parse(1_i64).as(Ledger::Accounts::ID)

  def self.text_of(writer : Punch::Writer, sql : String, *args) : String
    writer.query_one?(sql, *args, &.read(String)) || raise "no row"
  end

  def self.order(writer : Punch::Writer, shipping : Ledger::Orders::Shipment = shipment, payment : Ledger::Payment? = nil,
                 billed_to : Ledger::Orders::BilledTo? = nil) : Ledger::Orders::Record
    Ledger::Orders::Table.insert(writer, account_id: ACME, shipping: shipping, payment: payment, billed_to: billed_to.try { |value| Punch::Secret.new(value) })
  end
end

describe "composites" do
  it "are built only through build and copy_with, which check bounds and rules" do
    Ledger::Geo.build(lat: 91.0, lng: 0.0).as(Punch::Invalid).code.should eq("out_of_range")
    geo = Ledger::Geo.build(lat: 52.5, lng: 13.4).as(Ledger::Geo)
    geo.copy_with(lat: -100.0).as(Punch::Invalid).code.should eq("out_of_range")
    geo.copy_with(lng: 13.5).as(Ledger::Geo).lng.should eq(13.5)

    too_many = Ledger::Orders::Shipment.build(address: CompositesSpec.address, lines: Array.new(51) { CompositesSpec.line }, prices: {} of Punch::Currency => Punch::Money)
    too_many.as(Punch::Invalid).code.should eq("too_many")
    too_many.as(Punch::Invalid).params.should eq({"max" => 50, "field" => "lines"})

    long = Ledger::Orders::Shipment.build(address: CompositesSpec.address, lines: [CompositesSpec.line], prices: {} of Punch::Currency => Punch::Money, note: "x" * 17_000)
    long.as(Punch::Invalid).code.should eq("too_large")
  end

  it "fill defaults and compare declared fields only" do
    address = CompositesSpec.address
    address.country.value.should eq("DE")
    CompositesSpec.shipment.express.should be_false
    address.should eq(CompositesSpec.address)
    address.should_not eq(CompositesSpec.address("Hamburg"))
  end

  it "answer with their declared fields, never the stored form" do
    shipping = CompositesSpec.shipment(payment: CompositesSpec.card)
    json = JSON.parse(shipping.to_json)
    json["address"]["city"].should eq("Berlin")
    json["prices"].should eq(JSON.parse(%({"EUR": 1250})))
    json["payment"]["kind"].should eq("card")
    json.as_h.has_key?("note").should be_false
    json.as_h.has_key?("$v").should be_false
  end

  it "store a group of columns and read it back as one field" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        geo = Ledger::Geo.build(lat: 52.5, lng: 13.4).as(Ledger::Geo)
        contact = Ledger::Contact.build(name: CompositesSpec.text("Ann"), phone: Punch::Secret.new(CompositesSpec.text("+49 30 1"))).as(Ledger::Contact)
        site = Ledger::Sites::Table.insert(writer, account_id: CompositesSpec::ACME, name: "HQ", address: CompositesSpec.address(geo: geo), contact: contact)
        site.address.geo.should eq(geo)
        site.billing.should be_nil
        site.contact.phone.try(&.unwrap.value).should eq("+49 30 1")
        writer.query_one?("SELECT address_city, address_geo_lat, billing_street, typeof(contact_phone), typeof(contact_phone_index) FROM sites") { |row| {row.read(String), row.read(Float64), row.read(String?), row.read(String), row.read(String)} }.should eq({"Berlin", 52.5, nil, "blob", "blob"})

        billing = CompositesSpec.address("Hamburg")
        updated = Ledger::Sites::Table.update(writer, site.copy_with(billing: billing)).should_not be_nil
        updated.billing.should eq(billing)
        Ledger::Queries.site_by_id(writer, id: site.id).try(&.billing).should eq(billing)

        rows = Ledger::Queries.sites_in_city(writer, account_id: CompositesSpec::ACME, city: CompositesSpec.text("Berlin"))
        rows.map(&.address.city.value).should eq(["Berlin"])
        Ledger::Queries.site_cities(writer, account_id: CompositesSpec::ACME).map(&.address_city.value).should eq(["Berlin"])
      end
    end
  end

  it "refuse a group whose stored values break its rules, naming the columns" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        writer.exec("INSERT INTO sites (id, account_id, name, address_street, address_city, address_geo_lat, address_geo_lng, contact_name) VALUES (1, 1, 'HQ', 'Main St 1', 'Berlin', 95.0, 0.0, 'Ann')")
        error = expect_raises(Punch::Database::RowError) { Ledger::Sites::Table.find(writer, Ledger::Sites::ID.parse(1_i64).as(Ledger::Sites::ID)) }
        {error.table, error.column, error.row_id, error.reason}.should eq({"sites", "address_geo_*", 1, "out_of_range"})
      end
    end
  end

  it "store documents, plain, encrypted, and polymorphic, and read them back" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        billed = Ledger::Orders::BilledTo.build(name: CompositesSpec.text("Ann"), company: "Ann GmbH").as(Ledger::Orders::BilledTo)
        order = CompositesSpec.order(writer, CompositesSpec.shipment(payment: CompositesSpec.card), CompositesSpec.card, billed)
        order.shipping.should eq(CompositesSpec.shipment(payment: CompositesSpec.card))
        order.billed_to.try(&.unwrap).should eq(billed)

        case payment = order.payment
        in Ledger::Card     then payment.last4.value.should eq("4242")
        in Ledger::Transfer then fail "a card was stored"
        in Nil              then fail "a payment was stored"
        end

        raw = writer.query_one?("SELECT shipping, payment, typeof(billed_to) FROM orders") { |row| {row.read(String), row.read(String), row.read(String)} }.should_not be_nil
        JSON.parse(raw[0])["lines"][0]["unit_price"].should eq(300)
        JSON.parse(raw[1]).should eq(JSON.parse(%({"kind": "card", "last4": "4242", "brand": "visa"})))
        raw[2].should eq("blob")

        transfer = Ledger::Transfer.build(iban: CompositesSpec.text("DE00"), booked_at: Time.utc(2026, 10, 1)).as(Ledger::Transfer)
        Ledger::Queries.set_payment(writer, payment: transfer, id: order.id)
        Ledger::Orders::Table.find(writer, order.id).try(&.payment).should eq(transfer)
        JSON.parse(CompositesSpec.text_of(writer, "SELECT payment FROM orders"))["booked_at"].should eq("2026-10-01T00:00:00.000000000Z")
      end
    end
  end

  it "keep keys a newer release wrote when a document is changed and written back" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer)
        writer.exec("UPDATE orders SET shipping = json_set(shipping, '$.gift', json('{\"wrap\":true}'), '$.address.floor', 3)")
        read = Ledger::Orders::Table.find(writer, order.id).should_not be_nil
        read.shipping.should eq(order.shipping) # declared fields only
        changed = read.shipping.copy_with(note: "fragile").as(Ledger::Orders::Shipment)
        Ledger::Orders::Table.update(writer, read.copy_with(shipping: changed))
        stored = JSON.parse(CompositesSpec.text_of(writer, "SELECT shipping FROM orders"))
        {stored["gift"]["wrap"], stored["address"]["floor"], stored["note"]}.should eq({true, 3, "fragile"})

        built = Ledger::Orders::Shipment.build(address: read.shipping.address, lines: read.shipping.lines, prices: read.shipping.prices).as(Ledger::Orders::Shipment)
        JSON.parse(Punch::Stored.dump(built)).as_h.has_key?("gift").should be_false
      end
    end
  end

  it "read older versions through their frozen types and refuse newer ones" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer)
        encrypt = ->(text : String) { Punch::Stored.encryptor("orders", "billed_to").encrypt(text.to_slice) }
        writer.exec("UPDATE orders SET billed_to = ?", encrypt.call(%({"name": "Ann"})))
        Ledger::Orders::Table.find(writer, order.id).try(&.billed_to).try(&.unwrap.name.value).should eq("Ann")

        writer.exec("UPDATE orders SET billed_to = ?", encrypt.call(%({"$v": 3, "name": "Ann"})))
        error = expect_raises(Punch::Database::RowError) { Ledger::Orders::Table.find(writer, order.id) }
        {error.column, error.reason, error.path}.should eq({"billed_to", "newer_version", "$"})

        billed = Ledger::Orders::BilledTo.build(name: CompositesSpec.text("Bea")).as(Ledger::Orders::BilledTo)
        JSON.parse(Punch::Stored.dump(billed))["$v"].should eq(2)
      end
    end
  end

  it "name the path and reason of a document that does not parse, never the value" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer, CompositesSpec.shipment(lines: 2))
        writer.exec("UPDATE orders SET shipping = json_set(shipping, '$.lines[1].quantity', 'secret-ish')")
        error = expect_raises(Punch::Database::RowError) { Ledger::Orders::Table.find(writer, order.id) }
        {error.table, error.column, error.row_id, error.reason, error.path}.should eq({"orders", "shipping", order.id.value, "not_real", "$.lines[1].quantity"})
        error.message.to_s.should_not contain("secret-ish")

        writer.exec("UPDATE orders SET shipping = json_set(json_remove(shipping, '$.lines[1]'), '$.payment', json('{\"kind\":\"cash\"}'))")
        expect_raises(Punch::Database::RowError, /\$\.payment\.kind: unknown_member/) { Ledger::Orders::Table.find(writer, order.id) }
      end
    end
  end

  it "type paths into documents in queries and generated columns" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer, CompositesSpec.shipment(payment: CompositesSpec.card))
        row = Ledger::Queries.orders_in(writer, account_id: CompositesSpec::ACME, city: CompositesSpec.text("Berlin")).first
        {row.id, row.city.value, row.first_quantity, row.payment_kind, row.express, row.euros.try(&.value), row.ship_city.try(&.value)}.should eq(
          {order.id, "Berlin", 2.5, "card", false, 1250, "Berlin"})
        row.address.should eq(CompositesSpec.address)
        Ledger::Queries.orders_to_country(writer, account_id: CompositesSpec::ACME, country: CompositesSpec.text("DE")).map(&.id).should eq([order.id])
      end
    end
  end

  it "go into stored JSON and out again through their parser" do
    shipping = CompositesSpec.shipment(payment: CompositesSpec.card)
    Punch::Stored.from_json(Ledger::Orders::Shipment, Punch::Stored.json(shipping)).should eq(shipping)
    expect_raises(JSON::ParseException, /out_of_range/) { Punch::Stored.from_json(Ledger::Geo, %({"lat": 100, "lng": 0})) }
  end

  it "describe themselves in JSON Schema" do
    schema = Punch::JSONSchema.of(Ledger::Orders::Shipment)
    shipment = schema["$defs"]["Ledger.Orders.Shipment"]
    shipment["properties"]["lines"]["maxItems"].should eq(50)
    shipment["properties"]["prices"]["maxProperties"].should eq(5)
    shipment["properties"]["prices"]["propertyNames"]["type"].should eq("string")
    shipment["required"].as_a.map(&.as_s).should eq(%w[address lines prices express])
    schema["$defs"]["Ledger.Card"]["properties"]["kind"]["const"].should eq("card")
    payment = Punch::JSONSchema.of(Ledger::Payment)
    payment["oneOf"].as_a.map(&.["$ref"]).should eq(["#/$defs/Ledger.Card", "#/$defs/Ledger.Transfer"])
    payment["discriminator"]["propertyName"].should eq("kind")

    locked = Punch::Payloads.schema(Ledger::Orders::Shipment)
    locked["$defs"]["Ledger.Orders.Shipment"]["required"].as_a.map(&.as_s).should eq(%w[address lines prices])
  end
end

describe "documents across versions (docs/composites.md, Versions)" do
  it "rewrites documents of older versions and in other forms, and leaves those a newer release wrote" do
    CompositesSpec.with_db do |db|
      encrypt = ->(text : String) { Punch::Stored.encryptor("orders", "billed_to").encrypt(text.to_slice) }
      old, reordered, newer = db.write do |writer|
        {CompositesSpec.order(writer), CompositesSpec.order(writer), CompositesSpec.order(writer)}
      end
      db.write do |writer|
        writer.exec("UPDATE orders SET billed_to = ? WHERE id = ?", encrypt.call(%({"name": "Ann"})), old.id.value)
        stored = JSON.parse(CompositesSpec.text_of(writer, "SELECT shipping FROM orders WHERE id = ?", reordered.id.value)).as_h
        backwards = stored.to_a.reverse!.to_h.merge({"gift" => JSON::Any.new("yes")})
        writer.exec("UPDATE orders SET shipping = ? WHERE id = ?", backwards.to_json, reordered.id.value)
        writer.exec("UPDATE orders SET billed_to = ? WHERE id = ?", encrypt.call(%({"$v": 3, "name": "Cy"})), newer.id.value)
      end

      audit = Punch::Database::Audit.run(db)
      audit.documents.find!(&.column.==("billed_to")).versions.should eq({"Ledger::Orders::BilledTo version 1" => 1, "Ledger::Orders::BilledTo version 3" => 1})
      audit.documents.find!(&.column.==("shipping")).versions.should eq({"Ledger::Orders::Shipment version 1" => 3, "Ledger::Address version 1" => 3, "Ledger::Line version 1" => 3})

      run = Punch::Database::Upgrade.run(db, batch: 2)
      run.clean?.should be_false
      run.messages.should eq([
        "orders.billed_to: 1 rewritten, 1 left as they are (1 newer_version); rows #{newer.id.value}",
        "orders.shipping: 1 rewritten",
      ])
      db.read do |reader|
        plain = Punch::Stored.encryptor("orders", "billed_to").decrypt(reader.query_one?("SELECT billed_to FROM orders WHERE id = ?", old.id.value, &.read(Bytes)) || raise "no row") || raise "not decrypting"
        JSON.parse(String.new(plain)).should eq(JSON.parse(%({"$v": 2, "name": "Ann"})))
        shipping = JSON.parse(reader.query_one?("SELECT shipping FROM orders WHERE id = ?", reordered.id.value, &.read(String)) || raise "no row")
        {shipping.as_h.keys.last, shipping["gift"]}.should eq({"gift", "yes"}) # declared keys first, the newer key kept
      end
      Punch::Database::Upgrade.run(db).written.should be_empty
    end
  end

  it "locks each document's version, schema, and frozen types, and compares them like payloads" do
    entry = Punch::Job::Queue::Registry.document(Ledger::Orders::BilledTo)
    entry["version"].should eq(2)
    entry["frozen"]["1"]["$defs"]["Ledger.Orders.BilledTo.V1"]["required"].should eq(JSON.parse(%(["name"])))
    Punch::Job::Queue::Registry.documents.keys.should contain("Ledger::Orders::Shipment")
    Punch::Job::Queue::Registry.documents.keys.should_not contain("Ledger::Payment")

    v1 = JSON.parse({version: 1, schema: entry["frozen"]["1"]}.to_json)
    lock = ->(documents : Hash(String, JSON::Any)) { JSON.parse({types: {} of String => String, payloads: {} of String => String, documents: documents}.to_json) }
    upgraded = Punch::Payloads::Lock.new(lock.call({"Ledger::Orders::BilledTo" => v1}), lock.call({"Ledger::Orders::BilledTo" => entry}))
    {upgraded.ok?, upgraded.notes}.should eq({true, ["Ledger::Orders::BilledTo: version 1 to 2"]})

    breaking = JSON.parse({version: 2, schema: v1["schema"]}.to_json)
    broken = Punch::Payloads::Lock.new(lock.call({"Ledger::Orders::BilledTo" => entry}), lock.call({"Ledger::Orders::BilledTo" => breaking}))
    broken.ok?.should be_false
    broken.problems.first.should contain("raise the composite's version: version: N, from: {N - 1 => V1}")
    broken.ways_out.should eq("")
  end
end

describe "documents' nesting bound" do
  it "refuses a document nested deeper than its composite allows, while parsing" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer)
        deep = "[" * 40 + "]" * 40
        writer.exec("UPDATE orders SET shipping = json_set(shipping, '$.gift', json(?))", deep)
        error = expect_raises(Punch::Database::RowError) { Ledger::Orders::Table.find(writer, order.id) }
        {error.reason, error.path}.should eq({"too_deep", "$"})

        writer.exec("UPDATE orders SET shipping = json_set(json_remove(shipping, '$.gift'), '$.gift', json(?))", "[" * 20 + "]" * 20)
        Ledger::Orders::Table.find(writer, order.id).should_not be_nil # within 32: kept, and written back
      end
    end
    expect_raises(JSON::ParseException, /too_deep/) { Punch::Stored.from_json(Ledger::Geo, %({"lat": 1, "lng": 2, "x": #{"[" * 40}#{"]" * 40}})) }
  end
end

describe "composites against hostile stored data (security review, S15)" do
  it "refuses a document with a key twice, which SQLite's paths and a hash would read differently" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer)
        writer.exec("UPDATE orders SET payment = ?", %({"kind": "card", "last4": "4242", "brand": "visa", "brand": "amex"}))
        expect_raises(Punch::Database::RowError, /duplicate_key/) { Ledger::Orders::Table.find(writer, order.id) }
      end
    end
  end

  it "names a map's entries by position, never by their keys, which are data" do
    CompositesSpec.with_db do |db|
      db.write do |writer|
        order = CompositesSpec.order(writer)
        writer.exec("UPDATE orders SET shipping = json_set(shipping, '$.prices', json('{\"EUR\": 1, \"ann@example.org\": 2}'))")
        error = expect_raises(Punch::Database::RowError) { Ledger::Orders::Table.find(writer, order.id) }
        {error.reason, error.path}.should eq({"invalid_key", "$.prices{1}"})
        error.message.to_s.should_not contain("ann@")
      end
    end
  end

  it "reads a composite from JSON only when it is stored JSON, where IDs are rowids" do
    text = %({"description": "Work", "quantity": 1, "unit_price": 100, "customer_id": 7})
    expect_raises(JSON::ParseException, /not_stored_json/) { Ledger::Line.from_json(text) }
    Punch::Stored.from_json(Ledger::Line, text).customer_id.try(&.value).should eq(7)
  end

  it "refuses a Float64 that JSON cannot hold, as a value, not an exception" do
    Ledger::Line.build(description: CompositesSpec.text("Work"), quantity: Float64::INFINITY, unit_price: CompositesSpec.money(1)).as(Punch::Invalid).code.should eq("not_finite")
  end
end
