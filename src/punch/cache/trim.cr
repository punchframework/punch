module Punch::Caches
  # Removes expired cache entries every ten minutes: from `cache.db`, and
  # from the memory of the stores in the process that runs the job. Writes
  # trim as well, so this bounds what idle stores keep. A separate jobs
  # process (`punch jobs`) trims its own memory, not the server's; the
  # server's memory stores trim themselves on every write.
  @[Punch::Job::Recurring(every: 10.minutes)]
  struct Trim
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      now = Time.utc
      memory = Caches.stores.sum(0_i64, &.trim_memory(now).to_i64)
      file = Caches.durable.try(&.clear(expired_at: now)) || 0_i64
      if (event = Trace.event).recording?
        event.set("punch.cache.trimmed_memory", memory)
        event.set("punch.cache.trimmed_file", file)
      end
      nil
    end
  end
end
