module Punch::Spec
  # `.should be_rate_limited`: 429 with `Retry-After`, refused by the
  # limit named *by* when given.
  struct RateLimitedExpectation
    def initialize(@by : String?)
    end

    def match(actual : Response) : Bool
      return false unless actual.status.too_many_requests? && actual.headers.has_key?("Retry-After")

      by = @by || return true
      actual.headers["RateLimit"]?.try(&.starts_with?(%("#{by}";))) || false
    end

    def failure_message(actual : Response) : String
      "Expected: 429 with Retry-After#{@by.try { |name| " from #{name}" }}\n     got: #{actual.status.code} #{actual.headers["RateLimit"]?}"
    end

    def negative_failure_message(actual : Response) : String
      "Expected not to be rate limited, got 429 (#{actual.headers["RateLimit"]?})"
    end
  end

  # :nodoc:
  def self.reset_rate_limits : Nil
    RateLimits.reset
  end
end

# Every example starts with every key at its full limit. Durable limits use
# the in-memory `cache.db` that `punch/spec` attaches.
Spec.before_each { Punch::Spec.reset_rate_limits }

def be_rate_limited(by : String? = nil)
  Punch::Spec::RateLimitedExpectation.new(by)
end
