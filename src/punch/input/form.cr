require "uri"

module Punch::Input
  # Names in a form body: a field of a nested input is
  # `address[street]`, an element of an array of inputs `lines[0][...]`.
  module Form
    # The name of *field* inside *prefix*, the name of the nested input it
    # belongs to (`nil` at the top).
    def self.key(prefix : String?, field : String) : String
      prefix ? "#{prefix}[#{field}]" : field
    end

    # *values* as a form body would carry them: what a form shows before
    # anything is sent, and what `Punch::Spec` submits. Checked at compile
    # time against *type*: every key a field that is not a path parameter,
    # every value of its field's type; nested inputs take named tuples.
    def self.encode(type : I.class, values : Nil) : URI::Params forall I
      URI::Params.new
    end

    # :ditto:
    def self.encode(type : I.class, values : NamedTuple) : URI::Params forall I
      params = URI::Params.new
      write(I, params, nil, values)
      params
    end

    # :nodoc:
    def self.write(type : I.class, params : URI::Params, prefix : String?, values : T) : Nil forall I, T
      {% begin %}
        {% fields = I.instance_vars.reject(&.annotation(Punch::PathParam)) %}
        {% names = fields.map(&.name.stringify) %}
        {% for key in T.keys %}
          {% unless names.includes?(key.stringify) %}
            {% raise "#{I} has no field `#{key}` a form can fill. Fields: #{names.empty? ? "none" : names.join(", ").id}" %}
          {% end %}
          {% field = fields.find { |candidate| candidate.name.stringify == key.stringify } %}
          {% base = field.type.union_types.reject(&.==(::Nil)).first %}
          {% given = T[key] %}
          {% for member in given.union_types %}
            {% if member == ::Nil %}
            {% elsif base < ::Punch::Input %}
              {% raise "#{I}##{key}: give a named tuple of #{base}'s fields, not #{member}" unless member < ::NamedTuple %}
            {% elsif base < ::Array && base.type_vars.first < ::Punch::Input %}
              {% unless (member < ::Array || member < ::Tuple) && member.type_vars.all? { |item| item < ::NamedTuple } %}
                {% raise "#{I}##{key}: give an array of named tuples of #{base.type_vars.first}'s fields, not #{member}" %}
              {% end %}
            {% elsif base < ::Array %}
              {% unless (member < ::Array || member < ::Tuple) && member.type_vars.all? { |item| item <= base.type_vars.first } %}
                {% raise "#{I}##{key} must be #{base}, not #{member}" %}
              {% end %}
            {% else %}
              {% raise "#{I}##{key} must be #{base}, not #{member}" unless member <= base %}
            {% end %}
          {% end %}
          {% if base < ::Punch::Input %}
            if %value{key} = values[{{ key.symbolize }}]
              write({{ base.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, params, key(prefix, {{ key.stringify }}), %value{key})
            end
          {% elsif base < ::Array && base.type_vars.first < ::Punch::Input %}
            if %rows{key} = values[{{ key.symbolize }}]
              %rows{key}.each_with_index do |item, index|
                write({{ base.type_vars.first.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, params, "#{key(prefix, {{ key.stringify }})}[#{index}]", item)
              end
            end
          {% elsif base < ::Array %}
            if %items{key} = values[{{ key.symbolize }}]
              %items{key}.each { |item| params.add(key(prefix, {{ key.stringify }}), Routing.segment(item)) }
            end
          {% else %}
            unless (%value{key} = values[{{ key.symbolize }}]).nil?
              params.add(key(prefix, {{ key.stringify }}), Routing.segment(%value{key}))
            end
          {% end %}
        {% end %}
      {% end %}
    end

    # :nodoc:
    # Adds *value* under *key*, as `Input#__punch_encode` writes a field.
    def self.add(params, key : String, value : Nil) : Nil
    end

    # :ditto:
    def self.add(params, key : String, value : Punch::Input) : Nil
      value.__punch_encode(params, key)
    end

    # :ditto:
    def self.add(params, key : String, value : Array) : Nil
      value.each_with_index do |item, index|
        if item.is_a?(Punch::Input)
          item.__punch_encode(params, "#{key}[#{index}]")
        else
          params.add(key, Routing.segment(item))
        end
      end
    end

    # :ditto:
    def self.add(params, key : String, value) : Nil
      params.add(key, Routing.segment(value))
    end

    # Whether nothing under *key* has a value: a nested input left empty,
    # which counts as absent.
    def self.blank?(form : URI::Params, key : String) : Bool
      start = "#{key}["
      form.each { |name, value| return false if name.starts_with?(start) && !value.empty? }
      true
    end

    # The rows of an array of inputs under *key*, in order, without the
    # rows whose fields are all empty: a form shows blank rows to add to.
    # The indexes must run from 0 without a gap, so that every error names
    # the row it came from.
    def self.rows(form : URI::Params, key : String) : Array(Int32) | Invalid
      start = "#{key}["
      seen = Set(Int32).new
      filled = Set(Int32).new
      form.each do |name, value|
        next unless name.starts_with?(start)
        close = name.index(']', start.size) || return Invalid.new("invalid_index")
        digits = name[start.size...close]
        return Invalid.new("invalid_index") unless digits.matches?(/\A(?:0|[1-9][0-9]{0,5})\z/)

        index = digits.to_i
        seen << index
        filled << index unless value.empty?
      end
      return Invalid.new("invalid_index") unless seen.max?.try(&.+(1)) == seen.size || seen.empty?

      filled.to_a.sort!
    end
  end
end
