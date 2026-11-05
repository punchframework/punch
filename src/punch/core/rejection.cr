module Punch
  # Input that was refused at the boundary, with every error found, not just
  # the first. Operations never see it: `Input | Rejection` is decided
  # before `call` runs. Rendered as Problem Details for JSON and as field
  # errors on forms.
  #
  # A rejection always holds at least one error; an empty one is a bug.
  struct Rejection
    # Where an error sits in the input: field names and array indexes from the
    # root, such as `["lines", 2, "amount"]`. The empty path is the input as a
    # whole, for cross-field rules.
    alias Path = Array(String | Int32)

    # One failed value, located in the input.
    struct FieldError
      getter path : Path
      getter code : String
      getter params : Hash(String, Invalid::Param)

      def initialize(@path : Path, @code : String, @params : Hash(String, Invalid::Param) = {} of String => Invalid::Param)
      end

      def self.new(path : Path, invalid : Invalid) : self
        new(path, invalid.code, invalid.params)
      end
    end

    getter errors : Array(FieldError)

    def initialize(@errors : Array(FieldError))
      raise ArgumentError.new("a rejection needs at least one error") if errors.empty?
    end

    def self.new(path : Path, invalid : Invalid) : self
      new([FieldError.new(path, invalid)])
    end

    # The errors at *path*, such as `rejection.at("email")`.
    def at(*path : String | Int32) : Array(FieldError)
      wanted = path.to_a
      errors.select(&.path.==(wanted))
    end

    # Collects errors while parsing several values, then yields either the
    # parsed result or a rejection.
    #
    # ```
    # errors = Punch::Rejection::Collector.new
    # email = errors.check("email", Punch::Email.parse(raw_email))
    # name = errors.check("name", Punch::NonEmptyString.parse(raw_name))
    # errors.result { Signup.new(email.not_nil!, name.not_nil!) }
    # ```
    #
    # The collector is a value for one parse on one fiber. It is not shared.
    # It keeps the first `MAX_ERRORS`, so that a request cannot make one
    # error per array element, a body's worth of them, before anyone
    # checked who sent it.
    class Collector
      MAX_ERRORS = 100

      getter errors = [] of FieldError

      def initialize(@prefix : Path = Path.new)
      end

      # Returns the parsed value, or records the error and returns `nil`.
      def check(path : String | Int32 | Path, result : T | Invalid) : T? forall T
        case result
        when Invalid
          add(path, result)
          nil
        else
          result
        end
      end

      def add(path : String | Int32 | Path, invalid : Invalid) : Nil
        @errors << FieldError.new(@prefix + Collector.path(path), invalid) if @errors.size < MAX_ERRORS
      end

      # A collector for a nested object or array element. Errors land in this
      # collector, prefixed with *path*.
      def nested(path : String | Int32 | Path) : Collector
        Collector.new(@prefix + Collector.path(path)).tap(&.share(@errors))
      end

      def empty? : Bool
        @errors.empty?
      end

      # The number of errors so far, nested collectors included.
      def size : Int32
        @errors.size
      end

      # Yields when nothing failed, and returns the block's value. Otherwise
      # returns the rejection, without calling the block.
      def result(& : -> T) : T | Rejection forall T
        empty? ? yield : Rejection.new(@errors.dup)
      end

      protected def share(errors : Array(FieldError)) : Nil
        @errors = errors
      end

      protected def self.path(path : String | Int32) : Path
        Path{path}
      end

      protected def self.path(path : Path) : Path
        path
      end
    end
  end
end
