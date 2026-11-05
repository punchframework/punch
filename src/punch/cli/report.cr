module Punch::CLI
  # The successful result of a command. Every report renders both as text for
  # people and as JSON for programs and agents, so neither can be forgotten.
  module Report
    abstract def to_text(io : IO) : Nil
    abstract def to_json(json : JSON::Builder) : Nil

    def to_json(io : IO) : Nil
      JSON.build(io) { |json| to_json(json) }
    end
  end

  # An expected failure of a command, rendered as
  # `{"error": {"code": ..., "message": ...}}` in JSON mode, with
  # `details` when the command has more to say than the message, such as
  # the result of each step of `punch check`.
  struct Failure
    USAGE_EXIT_CODE = 2

    getter code : String
    getter message : String
    getter exit_code : Int32
    getter details : JSON::Any?

    def initialize(@code : String, @message : String, @exit_code : Int32 = 1, @details : JSON::Any? = nil)
    end

    def self.usage(code : String, message : String) : self
      new(code, message, USAGE_EXIT_CODE)
    end

    def to_json(io : IO) : Nil
      JSON.build(io) do |json|
        json.object do
          json.field "error" do
            json.object do
              json.field "code", code
              json.field "message", message
              json.field "details", details if details
            end
          end
        end
      end
    end
  end
end
