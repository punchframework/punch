module Punch::Spec
  # `.should be_replay_of(first)`: the answer is the stored one, given
  # again under the same idempotency key: marked
  # `Idempotent-Replayed: true`, with the first answer's status, type,
  # location, and body.
  struct ReplayExpectation
    def initialize(@first : Response)
    end

    def match(actual : Response) : Bool
      actual.replayed? && !@first.replayed? && actual.status == @first.status && actual.body == @first.body &&
        actual.content_type == @first.content_type && actual.headers["Location"]? == @first.headers["Location"]?
    end

    def failure_message(actual : Response) : String
      "Expected a replay of #{describe(@first)}\n     got: #{describe(actual)}"
    end

    def negative_failure_message(actual : Response) : String
      "Expected not a replay, got #{describe(actual)}"
    end

    private def describe(response : Response) : String
      "#{response.status.code}#{" (replayed)" if response.replayed?} #{response.content_type} #{response.body[0, 200]}"
    end
  end
end

def be_replay_of(first : Punch::Spec::Response)
  Punch::Spec::ReplayExpectation.new(first)
end
