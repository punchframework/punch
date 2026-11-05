module Punch
  # A failure result: a type that answers a status from 400 to 599 as
  # Problem Details (docs/openapi.md). Including it adds
  # `JSON::Serializable` and the empty constructor (the failure with no
  # fields is `NotFound.new`), and it requires the status, so a failure
  # cannot answer 200 and commit by omission: without
  # `@[Punch::Status(400..599)]` (a status in that range) it does not
  # compile.
  #
  # ```
  # @[Punch::Status(404)]
  # struct NotFound
  #   include Punch::Problem
  # end
  # ```
  #
  # A failure with fields defines its own `initialize`, and `NotFound.new`
  # is then not available.
  module Problem
    macro included
      include ::JSON::Serializable

      {% status = @type.annotation(::Punch::Status) %}
      {% unless status && status[0].is_a?(NumberLiteral) && status[0] >= 400 && status[0] <= 599 %}
        {% @type.raise "#{@type} includes Punch::Problem, so it needs @[Punch::Status(code)] with a status from 400 to 599 (lib/punch/docs/openapi.md)." %}
      {% end %}

      # The failure without fields: `NotFound.new`. One with fields is
      # made with them.
      def self.new : self
        \{% if @type.instance_vars.empty? %}
          allocate
        \{% else %}
          \{% raise "#{@type} has fields: make it with them, `#{@type}.new(...)`" %}
        \{% end %}
      end
    end
  end
end
