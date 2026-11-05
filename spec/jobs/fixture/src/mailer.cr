# The app behind spec/cli/jobs_lock_cli_spec.cr: a job and an event with a
# deferred subscriber, whose payloads punch jobs:lock records. The spec
# edits this file between runs.
require "punch"

module Mailer
  struct Welcome
    include Punch::Job

    getter user_id : Int64

    def initialize(@user_id)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  struct SignedUp
    include Punch::Event

    getter user_id : Int64

    def initialize(@user_id)
    end
  end

  @[Punch::Subscriber::Delivery(:deferred)]
  struct Greet
    include Punch::Subscriber(SignedUp)

    def call(event : SignedUp, job : Punch::Job::Context) : Punch::Job::Result
    end
  end
end
