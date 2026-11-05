module Punch
  module Authorization
    # What `authz:explain` found: the policy of one operation, run for one
    # user with given path parameters.
    record Explanation, operation : String, type : String, policy : String, decision : Policy::Decision, roles : String? do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "operation", operation
          json.field "type", type
          json.field "policy", policy
          json.field "decision", decision.to_s.underscore
          json.field "roles", roles
        end
      end
    end

    # :nodoc:
    alias Explainer = Proc(Database, Int64, Hash(String, String), Explanation | String)

    # One explainer per operation with a policy, by operation ID.
    # :nodoc:
    def self.explainers : Hash(String, Explainer)
      {% begin %}
        {
          {% for op in Punch::Operation.all_subclasses.reject(&.abstract?) %}
            {% if op.has_constant?("PunchPolicy") %}
              {{ op.name.split("::").map(&.underscore).join(".") }} => Explainer.new { |database, user_id, params| explain({{ op.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, database, user_id, params) },
            {% end %}
          {% end %}
        } of String => Explainer
      {% end %}
    end

    # Runs *operation*'s policy for *user_id* with the path parameters
    # *params*, as a request from a session that signed in just now would,
    # in a transaction that is rolled back. Returns why it cannot, as text.
    # :nodoc:
    def self.explain(operation : O.class, database : Database, user_id : Int64, params : Hash(String, String)) : Explanation | String forall O
      {% begin %}
        {% fields = parse_type("::#{O}::Input").resolve.instance_vars.select(&.annotation(Punch::PathParam)) %}
        {% actor = nil %}
        {% optional = false %}
        {% for type in parse_type("::#{O}::PunchCallExtras").resolve.type_vars %}
          {% members = type.union? ? type.union_types.reject(&.==(Nil)) : [type] %}
          {% if members.size == 1 && members[0] < Punch::Auth::Actor %}
            {% actor = members[0] %}
            {% optional = type.union? %}
          {% end %}
        {% end %}
        names = [{{ fields.map(&.name.stringify).splat }}] of String
        unknown = params.keys - names
        unless unknown.empty?
          return "#{O} has no path parameter #{unknown.first}; it takes #{names.empty? ? "none" : names.join(", ")}."
        end
        {% for field in fields %}
          raw = params[{{ field.name.stringify }}]? || return "#{O} needs the path parameter {{ field.name }}={{ field.type }}."
          %value{field.name} = case parsed = Input::Read.string({{ field.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, raw)
                               in Invalid then return "{{ field.name }}=#{raw} is not a {{ field.type }} (#{parsed.code})."
                               in {{ field.type.stringify.gsub(::Punch::NAME_STARTS, "::").id }} then parsed
                               end
        {% end %}
        now = Time.utc
        principal = Auth::Principal.new(user_id, Auth::Session.new(0_i64, user_id, "explain", now, now, now, now + 1.hour, nil, nil))
        tracer = Trace::Tracer.new(exporters: [Trace::MemoryExporter.new] of Trace::Exporter, events: [] of Trace::EventSink)
        root = tracer.start("authz.explain", :internal)
        checked = begin
          Trace.with(root) do
            {% if O < Punch::Command %}
              database.write do |db|
                db.lease.rollback_only = true
            {% else %}
              database.read do |db|
            {% end %}
                actor = {{ actor.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.load(principal, db)
                {% unless optional %}
                  next nil unless actor
                {% end %}
                Grant(O).check(actor, db{% for field in fields %}, {{ field.name }}: %value{field.name}{% end %})
              end
          end
        ensure
          root.finish
        end
        return "User #{user_id} does not load as {{ actor }}: no such user?" if checked.nil?
        decision = checked.is_a?(Policy::Refused) ? checked.decision : Policy::Decision::Allow
        Explanation.new({{ O.name.split("::").map(&.underscore).join(".") }}, {{ O.name.stringify }}, O::PunchPolicy.name,
          decision, root.attributes["punch.roles"]?.try(&.to_s))
      {% end %}
    end
  end
end
