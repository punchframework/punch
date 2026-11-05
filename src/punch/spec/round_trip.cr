module Punch::Spec
  # Checks a tier-2 store: saving each model and loading it back returns an
  # equal model. A field the mapper forgets is a quiet bug that only this
  # shows. The block saves and loads; *covering* names the union of states,
  # and the example fails unless every state was given:
  #
  # ```
  # Punch::Spec.round_trip(draft, sent, covering: Invoice::Any) do |invoice|
  #   Invoices::Store.save(db, invoice)
  #   Invoices::Store.load(db, invoice.id)
  # end
  # ```
  #
  # A failure names each field that came back different. Give fields values
  # other than their defaults (a set `due_at`, a non-zero amount), or a
  # forgotten one comes back equal by chance.
  def self.round_trip(*models : *T, covering : U.class, file = __FILE__, line = __LINE__, &) forall T, U
    round_trip(*models, file: file, line: line) { |model| yield model }
    {% begin %}
      %given = [{% for type in T %} {{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.name, {% end %}] of String
      %missing = [{% for member in U.union_types %} {{ member.stringify.gsub(::Punch::NAME_STARTS, "::").id }}.name, {% end %}] of String
      %missing.reject! { |name| %given.includes?(name) }
      unless %missing.empty?
        fail "Round trip covers no #{%missing.join(", ")}: give a model in every state of #{U}", file, line
      end
    {% end %}
  end

  # The same without a list of states, for a single model type.
  def self.round_trip(*models : *T, file = __FILE__, line = __LINE__, &) forall T
    {% begin %}
      {% for index in 0...T.size %}
        %loaded = yield models[{{ index }}]
        RoundTrip.check(models[{{ index }}], %loaded, file, line)
      {% end %}
    {% end %}
  end

  # :nodoc:
  module RoundTrip
    def self.check(saved : T, loaded, file : String, line : Int32) : Nil forall T
      return if loaded == saved

      unless loaded.is_a?(T)
        fail "Round trip of #{T} returned #{loaded.nil? ? "nil" : loaded.class}", file, line
      end
      fail "Round trip of #{T} changed #{differences(saved, loaded).join(", ")}", file, line
    end

    # The fields that differ, each with what was saved and what came back.
    def self.differences(saved : T, loaded : T) : Array(String) forall T
      changed = [] of String
      {% for ivar in T.instance_vars %}
        if saved.@{{ ivar.id }} != loaded.@{{ ivar.id }}
          changed << "#{{{ ivar.stringify }}}: saved #{saved.@{{ ivar.id }}.inspect}, loaded #{loaded.@{{ ivar.id }}.inspect}"
        end
      {% end %}
      changed.empty? ? ["nothing field by field, but == is false"] : changed
    end
  end
end
