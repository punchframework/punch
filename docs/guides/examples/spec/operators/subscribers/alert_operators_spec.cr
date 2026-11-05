require "../../spec_helper"

module AlertSpec
  # A job that fails for good on its first attempt.
  @[Punch::Job::Options(attempts: 1)]
  struct Fail
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      raise ArgumentError.new("no luck")
    end
  end
end

describe Operators::AlertOperators do
  it "mails the operators once for each trouble: the error, and the job type failing for good" do
    Punch::Spec.ops
    Punch::Job::Queue.enqueue(AlertSpec::Fail.new)
    Punch::Spec.perform_jobs
    2.times do
      Punch::Job::Queue.enqueue(Punch::Ops::Notify.new)
      Punch::Spec.perform_jobs
    end
    Punch::Spec.mails.map { |mail| {mail.to, mail.subject} }.should eq([
      {["ops@example.org"], "Alert: ArgumentError in job AlertSpec::Fail"},
      {["ops@example.org"], "Alert: AlertSpec::Fail: 1 failed, 0 unreadable"},
    ])
  end
end
