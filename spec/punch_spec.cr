require "./spec_helper"

describe Punch do
  it "has a version" do
    Punch::VERSION.should match(/\A\d+\.\d+\.\d+/)
  end
end

describe "the spec environment" do
  it "runs the default execution context with the configured parallelism" do
    expected = Fiber::ExecutionContext.default_workers_count
    Fiber::ExecutionContext.default.capacity.should eq(expected)
  end

  it "runs fibers on several threads at the same time" do
    n = Fiber::ExecutionContext.default.capacity
    next if n < 2

    # Each fiber spins without yielding until all of them have started, which
    # only finishes in time if they really run on separate threads.
    started = Atomic(Int32).new(0)
    done = Channel(Bool).new(n)
    deadline = Time.instant + 5.seconds
    n.times do
      spawn do
        started.add(1)
        until started.get >= n || Time.instant > deadline
          Intrinsics.pause
        end
        done.send(started.get >= n)
      end
    end
    n.times { done.receive.should be_true }
  end
end
