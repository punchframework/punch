module Punch::Spec
  # A time that moves only when told to.
  class ManualClock
    property now : Time

    def initialize(@now : Time = Time.utc)
    end

    def advance(by span : Time::Span) : Time
      @now += span
    end
  end

  @@clock : ManualClock?

  # Stops `Time.utc` and `Time.local` for the whole process until the
  # example ends, in the app and in Punch alike: requests, sessions, jobs,
  # caches, and rate limits all read it. So a spec moves time instead of
  # rewriting rows:
  #
  # ```
  # clock = Punch::Spec.clock(Time.utc(2026, 3, 1))
  # client.get(path).json["overdue"] # not yet
  # clock.advance(40.days)
  # client.get(path).json["overdue"] # now
  # ```
  def self.clock(at time : Time) : ManualClock
    @@clock = ManualClock.new(time)
  end

  # This example's clock, stopped now if nothing stopped it yet.
  def self.clock : ManualClock
    @@clock ||= ManualClock.new
  end

  # :nodoc:
  def self.stopped_at : Time?
    @@clock.try(&.now)
  end

  # :nodoc:
  def self.reset_clock : Nil
    @@clock = nil
  end
end

# Loaded only with `punch/spec`: a build without it reads the system clock
# with nothing in between. `Time.instant` and `Time.utc(2026, 1, 1)` are
# left alone.
struct Time
  # :nodoc:
  def self.utc : Time
    Punch::Spec.stopped_at || previous_def
  end

  # :nodoc:
  def self.local(location : Location = Location.local) : Time
    Punch::Spec.stopped_at.try(&.in(location)) || previous_def
  end
end

Spec.before_each { Punch::Spec.reset_clock }
