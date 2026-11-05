require "../spec_helper"

module InputSpec
  struct InvoiceID < Punch::TypedID
  end

  enum Order
    Newest
    AmountDesc
  end

  struct Line
    include Punch::Input

    getter description : Punch::NonEmptyString
    getter cents : Int64
    getter quantity : Int32 = 1

    def check(errors : Punch::Rejection::Collector) : Nil
      errors.add("cents", Punch::Invalid.new("negative")) if cents < 0
    end
  end

  # Built in code as well as parsed, as generated filters are.
  struct Built
    include Punch::Input

    getter status : String?
    getter? unsent : Bool = false

    def initialize(*, @status : String? = nil, @unsent : Bool = false)
    end
  end

  struct Send
    include Punch::Input

    @[Punch::PathParam]
    getter invoice_id : InvoiceID

    getter recipient : Punch::Email
    getter note : String?
    getter copies : Int32 = 1
    getter? urgent : Bool = false
    getter ratio : Float64?
    getter at : Time?
    getter tags : Array(String)?
    getter lines : Array(Line)?
    getter order : Order?
    getter reviewer : InvoiceID?
  end

  struct Search
    include Punch::Input

    getter q : String?
    getter page : Int32 = 1
    getter order : Order = Order::Newest
    getter ids : Array(InvoiceID) = [] of InvoiceID
    getter since : Time?
    getter? exact : Bool?
  end

  # A list's input with a filter, as a page or a Query takes it.
  struct ListFilter
    include Punch::Input

    getter status : Order?
    getter min_cents : Int64?
    getter? unpaid : Bool = false

    def initialize(*, @status : Order? = nil, @min_cents : Int64? = nil, @unpaid : Bool = false)
    end

    def check(errors : Punch::Rejection::Collector) : Nil
      errors.add("min_cents", Punch::Invalid.new("negative")) if min_cents.try(&.negative?)
    end
  end

  struct List
    include Punch::Input

    getter filter : ListFilter = ListFilter.new
    getter limit : Int32 = 50
    getter tags : Array(String) = [] of String
  end

  struct Period
    include Punch::Input

    getter starts_on : Time
    getter ends_on : Time

    def check(errors : Punch::Rejection::Collector) : Nil
      errors.add(Punch::Rejection::Path.new, Punch::Invalid.new("ends_before_start")) if ends_on < starts_on
    end
  end

  struct Empty
    include Punch::Input
  end
end

private PATH = {"invoice_id" => "42"}

private def send(body : String, path = PATH)
  InputSpec::Send.from_json(body, path)
end

private def search(query : String)
  InputSpec::Search.from_query(URI::Params.parse(query))
end

describe Punch::Input do
  describe ".from_json" do
    it "reports at most a hundred errors for an array of bad elements" do
      body = %({"recipient": "ann@example.org", "lines": [#{Array.new(10_000, "{}").join(",")}]})
      send(body).as(Punch::Rejection).errors.size.should eq(Punch::Rejection::Collector::MAX_ERRORS)
    end

    it "parses every supported type" do
      input = send(<<-JSON).as(InputSpec::Send)
        {"recipient": "Ann@Example.org", "note": "Thanks", "copies": 3, "urgent": true,
         "ratio": 0.5, "at": "2026-10-08T09:30:00+02:00", "tags": ["a", "b"],
         "lines": [{"description": " Work ", "cents": 1500}], "order": "amount_desc", "reviewer": 7}
        JSON
      input.invoice_id.value.should eq(42)
      input.recipient.value.should eq("ann@example.org")
      input.note.should eq("Thanks")
      input.copies.should eq(3)
      input.urgent?.should be_true
      input.ratio.should eq(0.5)
      input.at.should eq(Time.utc(2026, 10, 8, 7, 30))
      input.tags.should eq(["a", "b"])
      line = input.lines.try(&.first) || fail "no lines"
      {line.description.value, line.cents, line.quantity}.should eq({"Work", 1500, 1})
      input.order.should eq(InputSpec::Order::AmountDesc)
      input.reviewer.try(&.value).should eq(7)
    end

    it "applies defaults and nil for absent optional fields" do
      input = send(%({"recipient": "ann@example.org"})).as(InputSpec::Send)
      input.note.should be_nil
      input.copies.should eq(1)
      input.urgent?.should be_false
      input.tags.should be_nil
    end

    it "takes null as absent for optional fields and as missing for required ones" do
      send(%({"recipient": "ann@example.org", "note": null})).as(InputSpec::Send).note.should be_nil
      send(%({"recipient": null})).should be_rejected("recipient", code: "required")
      send(%({"recipient": "ann@example.org", "copies": null})).should be_rejected("copies", code: "required")
    end

    it "collects every error with its path" do
      result = send(<<-JSON, {"invoice_id" => "0"})
        {"recipient": "nope", "copies": "3", "urgent": 1, "ratio": "x", "at": "yesterday",
         "tags": ["a", 2, "c", false], "order": "oldest", "colour": "red",
         "lines": [{"description": "ok", "cents": 1}, {"description": " ", "cents": 1.5, "x": 1}, 7]}
        JSON
      result.should be_rejected("invoice_id", code: "invalid_id")
      result.should be_rejected("recipient", code: "invalid_email")
      result.should be_rejected("copies", code: "expected_integer")
      result.should be_rejected("urgent", code: "expected_boolean")
      result.should be_rejected("ratio", code: "expected_number")
      result.should be_rejected("at", code: "invalid_date_time")
      send(%({"recipient": "ann@example.org", "at": "2026-02-30T09:30:00Z"})).should be_rejected("at", code: "invalid_date_time")
      result.should be_rejected("tags", 1, code: "expected_string")
      result.should be_rejected("tags", 3, code: "expected_string")
      result.should be_rejected("order", code: "invalid_choice")
      result.should be_rejected("lines", 1, "description", code: "blank")
      result.should be_rejected("lines", 1, "cents", code: "expected_integer")
      result.should be_rejected("lines", 2, code: "expected_object")
      result.as(Punch::Rejection).errors.size.should eq(12)
    end

    it "reports missing required fields and path params" do
      result = send("{}", {} of String => String)
      result.should be_rejected("recipient", code: "required")
      result.should be_rejected("invoice_id", code: "required")
    end

    it "ignores unknown fields, also inside nested inputs" do
      input = send(%({"recipient": "a@b.co", "colour": {"deep": [1, 2]}, "lines": [{"description": "x", "cents": 1, "vat": 19}]}))
      input.as(InputSpec::Send).lines.try(&.size).should eq(1)
    end

    it "never takes a path param from the body" do
      input = send(%({"recipient": "a@b.co", "invoice_id": 7})).as(InputSpec::Send)
      input.invoice_id.value.should eq(42)
    end

    it "rejects a repeated key instead of taking the last one" do
      send(%({"recipient": "ann@example.org", "recipient": "eve@example.org"})).should be_rejected("recipient", code: "duplicate_field")
    end

    it "keeps integers in range and refuses non-finite numbers" do
      send(%({"recipient": "a@b.co", "copies": 2147483648})).should be_rejected("copies", code: "out_of_range")
      send(%({"recipient": "a@b.co", "reviewer": 99999999999999999999})).should be_rejected("reviewer", code: "out_of_range")
      send(%({"recipient": "a@b.co", "ratio": 1e400})).should be_rejected("ratio", code: "out_of_range")
      send(%({"recipient": "a@b.co", "ratio": 2})).as(InputSpec::Send).ratio.should eq(2.0)
    end

    it "accepts only the snake_case name of an enum member" do
      send(%({"recipient": "a@b.co", "order": "AmountDesc"})).should be_rejected("order", code: "invalid_choice")
      send(%({"recipient": "a@b.co", "order": "newest"})).as(InputSpec::Send).order.should eq(InputSpec::Order::Newest)
    end

    it "runs check on nested inputs and on the input as a whole" do
      send(%({"recipient": "a@b.co", "lines": [{"description": "x", "cents": -1}]})).should be_rejected("lines", 0, "cents", code: "negative")
      InputSpec::Period.from_json(%({"starts_on": "2026-10-08T00:00:00Z", "ends_on": "2026-10-01T00:00:00Z"})).should be_rejected(code: "ends_before_start")
    end

    it "runs check only when every field parsed" do
      result = InputSpec::Period.from_json(%({"starts_on": "2026-10-08T00:00:00Z"}))
      result.should be_rejected("ends_on", code: "required")
      result.as(Punch::Rejection).errors.size.should eq(1)
    end

    it "rejects malformed JSON and non-object bodies" do
      send(%({"recipient": )).should be_rejected(code: "malformed_json")
      send(%({"recipient": "a@b.co"} {})).should be_rejected(code: "malformed_json")
      send(%({"recipient": "a@b.co"}]")).should be_rejected(code: "malformed_json")
      send(%(["a@b.co"])).should be_rejected(code: "expected_object")
      send(%("a@b.co")).should be_rejected(code: "expected_object")
    end

    it "reports where malformed JSON broke" do
      error = send(%({\n  "recipient": x})).as(Punch::Rejection).errors.first
      error.params["line"].should eq(2)
    end

    it "treats an empty body as an empty object" do
      InputSpec::Empty.from_json("").should be_a(InputSpec::Empty)
      InputSpec::Empty.from_json("  \n").should be_a(InputSpec::Empty)
      InputSpec::Empty.from_json(%({"a": 1})).should be_a(InputSpec::Empty)
    end
  end

  describe ".from_query" do
    it "parses scalars, enums, primitives, and repeated keys as arrays" do
      input = search("q=caf%C3%A9&page=3&order=amount_desc&ids=4&ids=5&since=2026-10-08T00:00:00Z&exact=false").as(InputSpec::Search)
      input.q.should eq("café")
      input.page.should eq(3)
      input.order.should eq(InputSpec::Order::AmountDesc)
      input.ids.map(&.value).should eq([4, 5])
      input.since.should eq(Time.utc(2026, 10, 8))
      input.exact?.should be_false
    end

    it "uses defaults, and takes empty values as absent" do
      input = search("q=&page=&utm_source=newsletter").as(InputSpec::Search)
      input.q.should be_nil
      input.page.should eq(1)
      input.order.should eq(InputSpec::Order::Newest)
      input.ids.should be_empty
    end

    it "collects every error with its path" do
      result = search("page=two&page=3&order=Newest&ids=4&ids=-5&ids=x&exact=yes&since=today")
      result.should be_rejected("page", code: "duplicate_field")
      result.should be_rejected("order", code: "invalid_choice")
      result.should be_rejected("ids", 1, code: "invalid_id")
      result.should be_rejected("ids", 2, code: "expected_integer")
      result.should be_rejected("exact", code: "expected_boolean")
      result.should be_rejected("since", code: "invalid_date_time")
      result.as(Punch::Rejection).errors.size.should eq(6)
    end

    it "reads integers in their canonical form only" do
      ["+3", "03", "3.0", "1e2", " 3", "0x3"].each do |raw|
        search("page=#{URI.encode_www_form(raw)}").should be_rejected("page", code: "expected_integer")
      end
      search("page=2147483648").should be_rejected("page", code: "out_of_range")
      search("page=-3").as(InputSpec::Search).page.should eq(-3)
    end

    it "reads a nested input from bracketed names, as a form body carries it" do
      input = InputSpec::List.from_query(URI::Params.parse("filter[status]=amount_desc&filter[unpaid]=true&limit=10")).as(InputSpec::List)
      input.filter.should eq(InputSpec::ListFilter.new(status: :amount_desc, unpaid: true))
      input.limit.should eq(10)
      empty = InputSpec::List.from_query(URI::Params.parse("filter[status]=&filter=paid")).as(InputSpec::List)
      empty.filter.should eq(InputSpec::ListFilter.new)
    end

    it "names a nested input's errors by its path, its own check included" do
      result = InputSpec::List.from_query(URI::Params.parse("filter[status]=Paid&filter[min_cents]=x&limit=y"))
      result.should be_rejected("filter", "status", code: "invalid_choice")
      result.should be_rejected("filter", "min_cents", code: "expected_integer")
      result.should be_rejected("limit", code: "expected_integer")
      InputSpec::List.from_query(URI::Params.parse("filter[min_cents]=-1")).should be_rejected("filter", "min_cents", code: "negative")
    end

    it "writes what it holds back as a query string, without defaults, and reads it again" do
      params = URI::Params.new
      InputSpec::List.from_query(URI::Params.parse("filter[status]=newest&filter[min_cents]=5&tags=a&tags=b&limit=50"))
        .as(InputSpec::List).__punch_encode(params, nil)
      params.to_s.should eq("filter%5Bstatus%5D=newest&filter%5Bmin_cents%5D=5&tags=a&tags=b")
      again = InputSpec::List.from_query(params).as(InputSpec::List)
      again.filter.should eq(InputSpec::ListFilter.new(status: :newest, min_cents: 5))
      again.tags.should eq(%w[a b])
    end

    it "takes path params from the path, never from the query string" do
      result = InputSpec::Period.from_query(URI::Params.parse("starts_on=2026-10-08T00:00:00Z&ends_on=2026-10-09T00:00:00Z"))
      result.should be_a(InputSpec::Period)
    end
  end

  describe ".from_form" do
    it "parses a browser's form: scalars, checkboxes, repeated keys, and rows of nested inputs" do
      form = URI::Params.parse("recipient=ann%40example.org&urgent=true&tags=a&tags=b&order=newest" \
                               "&lines[0][description]=Design&lines[0][cents]=1250" \
                               "&lines[1][description]=Hosting&lines[1][cents]=900&lines[1][quantity]=3")
      input = InputSpec::Send.from_form(form, PATH).as(InputSpec::Send)
      input.invoice_id.value.should eq(42)
      input.urgent?.should be_true
      input.tags.should eq(["a", "b"])
      lines = input.lines || fail("no lines")
      lines.map { |line| {line.description.value, line.cents, line.quantity} }.should eq([{"Design", 1250, 1}, {"Hosting", 900, 3}])
    end

    it "takes empty values, unchecked boxes, and empty rows as absent" do
      form = URI::Params.parse("recipient=ann%40example.org&note=&copies=" \
                               "&lines[0][description]=&lines[0][cents]=&lines[1][description]=Design&lines[1][cents]=5" \
                               "&lines[2][description]=&lines[2][cents]=")
      input = InputSpec::Send.from_form(form, PATH).as(InputSpec::Send)
      {input.note, input.copies, input.urgent?}.should eq({nil, 1, false})
      (input.lines || fail("no lines")).map(&.description.value).should eq(["Design"])
      InputSpec::Send.from_form(URI::Params.parse("recipient=a%40b.org&lines[0][description]="), PATH).as(InputSpec::Send).lines.should be_nil
    end

    it "names each error by its row, as the form named the field" do
      form = URI::Params.parse("recipient=nope&recipient=twice&lines[0][description]=&lines[0][cents]=" \
                               "&lines[1][description]=x&lines[1][cents]=-1&lines[2][description]=y&lines[2][cents]=z")
      result = InputSpec::Send.from_form(form, PATH)
      result.should be_rejected("recipient", code: "duplicate_field")
      result.should be_rejected("lines", 1, "cents", code: "negative")
      result.should be_rejected("lines", 2, "cents", code: "expected_integer")
      result.as(Punch::Rejection).errors.size.should eq(3)
    end

    it "refuses rows with gaps or numbers it cannot read" do
      ["lines[1][description]=x", "lines[01][description]=x", "lines[a][description]=x", "lines[0[description]=x",
       "lines[1234567][description]=x"].each do |row|
        InputSpec::Send.from_form(URI::Params.parse("recipient=a%40b.org&#{row}"), PATH).should be_rejected("lines", code: "invalid_index")
      end
    end

    it "fills every field it can from typed values, as a form shows them" do
      params = Punch::Input::Form.encode(InputSpec::Send, {
        recipient: Punch::Email.parse("ann@example.org").as(Punch::Email), urgent: true, order: InputSpec::Order::AmountDesc,
        at: Time.utc(2026, 10, 9), tags: ["x", "y"], note: nil,
        lines: [{description: Punch::NonEmptyString.parse("Design").as(Punch::NonEmptyString), cents: 1250_i64}],
      })
      params.to_s.should eq("recipient=ann%40example.org&urgent=true&order=amount_desc&at=2026-10-09T00%3A00%3A00Z" \
                            "&tags=x&tags=y&lines%5B0%5D%5Bdescription%5D=Design&lines%5B0%5D%5Bcents%5D=1250")
      InputSpec::Send.from_form(params, PATH).should be_a(InputSpec::Send)
    end
  end

  describe "Punch::Spec.input" do
    it "builds an input from plain values" do
      input = Punch::Spec.input(InputSpec::Send, PATH, recipient: "ann@example.org", copies: 2)
      {input.invoice_id.value, input.copies}.should eq({42, 2})
    end

    it "fails the example with every error" do
      expect_raises(Spec::AssertionFailed, /did not parse: invalid_email at \["recipient"\], required at \["invoice_id"\]/) do
        Punch::Spec.input(InputSpec::Send, recipient: "nope")
      end
    end
  end

  it "parses in parallel without sharing state" do
    channel = Channel(Bool).new
    32.times do |fiber|
      spawn do
        ok = (1..200).all? do |copies|
          id = fiber * 1000 + copies

          case input = send(%({"recipient": "u#{id}@example.org", "copies": #{copies}}), {"invoice_id" => id.to_s})
          in InputSpec::Send  then input.invoice_id.value == id && input.copies == copies && input.recipient.value == "u#{id}@example.org"
          in Punch::Rejection then false
          end
        end
        channel.send(ok)
      end
    end
    32.times { channel.receive.should be_true }
  end

  it "keeps parsing when the input defines an initialize of its own" do
    InputSpec::Built.new(status: "sent").status.should eq("sent")
    InputSpec::Built.from_query(URI::Params.parse("unsent=true")).as(InputSpec::Built).unsent?.should be_true
    InputSpec::Built.from_json(%({"status": "draft"})).as(InputSpec::Built).status.should eq("draft")
    InputSpec::Built.from_form(URI::Params.parse("status=x")).as(InputSpec::Built).status.should eq("x")
    InputSpec::Built.from_query(URI::Params.parse("unsent=maybe")).should be_rejected("unsent", code: "expected_boolean")
  end
end
