module Punch::Spec
  # The events delivered after commit while the block runs, in this fiber,
  # in the order they were published: what requests through
  # `Punch::Spec.client` and writes through `Punch::Spec.db` published and
  # committed. Events of a Command that failed or raised are not among
  # them, because they were never delivered.
  #
  # ```
  # sent = Punch::Spec.published(Billing::InvoiceSent) { client.post(Invoices::Send.path(invoice_id: id)) }
  # sent.map(&.invoice_id).should eq([id])
  # ```
  def self.published(& : ->) : Array(Event)
    fiber = Fiber.current
    previous = fiber.punch_published
    recorded = fiber.punch_published = [] of Event
    begin
      yield
    ensure
      fiber.punch_published = previous
      previous.try(&.concat(recorded))
    end
    recorded
  end

  # Only the published events of type *type*.
  def self.published(type : T.class, & : ->) : Array(T) forall T
    published { yield }.compact_map(&.as?(T))
  end

  # The events handle of *operation* for a write it runs in, for specs
  # that call a Command directly. Its type is the one the Command's `call`
  # asks for:
  #
  # ```
  # db.write do |writer|
  #   Invoices::Send.new.call(input, writer, actor, Punch::Spec.grant(Invoices::Send, actor, writer, invoice_id: id),
  #     Punch::Spec.events(Invoices::Send, writer))
  # end
  # ```
  def self.events(operation : O.class, writer : Writer) forall O
    {% begin %}
      {% handle = parse_type("::#{O}::PunchCallExtras").resolve.type_vars.find { |type| type.name(generic_args: false) == "Punch::Events" } %}
      {% raise "#{O}#call takes no Punch::Events, so it publishes nothing." unless handle %}
      {{ handle.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.for_transaction(writer)
    {% end %}
  end
end

module Punch::Spec
  # What `publish` matches: a block that publishes events of type *T*
  # with these field values, *times* times when given.
  class PublishExpectation(T, F)
    @all = [] of Event
    @matching = [] of T

    def initialize(@times : Int32?, @fields : F)
    end

    def match(actual : Proc) : Bool
      @all = Spec.published { actual.call }
      @matching = @all.compact_map(&.as?(T)).select { |event| fields?(event) }
      (times = @times) ? @matching.size == times : !@matching.empty?
    end

    def failure_message(actual : Proc) : String
      "Expected the block to publish #{describe}\n     got: #{@all.empty? ? "no events" : @all.map(&.inspect).join(", ")}"
    end

    def negative_failure_message(actual : Proc) : String
      "Expected the block not to publish #{describe}\n     got: #{@matching.map(&.inspect).join(", ")}"
    end

    private def describe : String
      String.build do |io|
        io << (@times.try { |times| "#{times} × " } || "") << T
        io << " with " << @fields.to_s.lchop('{').rchop('}') unless @fields.empty?
      end
    end

    private def fields?(event : T) : Bool
      {% for key in F.keys %}
        {% unless T.has_method?(key) || T.ancestors.any?(&.has_method?(key)) %}
          {% raise "publish(#{T}, #{key}: …): #{T} has no `#{key}`" %}
        {% end %}
        return false unless event.{{ key }} == @fields[{{ key.symbolize }}]
      {% end %}
      true
    end
  end
end

# `->{ … }.should publish(Billing::InvoiceSent, invoice_id: id)`: the block
# publishes and commits at least one event of this type with these field
# values; `times: n` for exactly *n*. Events of a Command that failed are
# never published (docs/events.md).
def publish(type : T.class, *, times : Int32? = nil, **fields) forall T
  Punch::Spec::PublishExpectation(T, typeof(fields)).new(times, fields)
end
