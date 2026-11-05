module Punch
  # The reason one value failed to parse. Returned by every `.parse` of a domain
  # primitive in place of the value: `Email | Invalid`.
  #
  # ```
  # Punch::Invalid.new("too_long", max: 64)
  # ```
  struct Invalid
    # A value that goes with an error code, such as the maximum length in
    # `too_long`. Rejections carry codes and values, never sentences: messages
    # are rendered in the request's locale at the edge.
    alias Param = String | Int64 | Float64 | Bool

    CODE_FORMAT = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

    getter code : String
    getter params : Hash(String, Param)

    def self.new(code : String, **params) : self
      hash = {} of String => Param
      params.each { |key, value| hash[key.to_s] = Invalid.param(value) }
      new(code, hash)
    end

    def initialize(@code : String, @params : Hash(String, Param))
      raise ArgumentError.new("error code must be snake_case: #{code.inspect}") unless CODE_FORMAT.matches?(code)
    end

    protected def self.param(value : Param) : Param
      value
    end

    protected def self.param(value : Int) : Param
      value.to_i64
    end

    protected def self.param(value : Float) : Param
      value.to_f64
    end

    protected def self.param(value : Symbol) : Param
      value.to_s
    end
  end
end
