module Punch
  class Job::Queue
    # When a recurring job runs: a cron expression or a fixed interval,
    # always in UTC.
    abstract struct Schedule
      # The first run strictly after *time*, or `nil` if there is none
      # within five years (`0 0 30 2 *`).
      abstract def next_after(time : Time) : Time?

      # How it was written, for `jobs:types`.
      abstract def to_s(io : IO) : Nil
    end

    # Every *interval*, at multiples of it counted from the Unix epoch, so
    # that every process computes the same times: `every: 1.hour` runs on
    # the hour, `every: 15.minutes` at :00, :15, :30, and :45.
    struct Every < Schedule
      getter interval : Time::Span

      def initialize(@interval : Time::Span)
        raise ArgumentError.new("a recurring interval is at least one minute, got #{@interval}") if @interval < 1.minute
      end

      def next_after(time : Time) : Time?
        step = @interval.total_milliseconds.to_i64
        Time.unix_ms((time.to_unix_ms // step + 1) * step)
      end

      def to_s(io : IO) : Nil
        io << "every " << @interval
      end
    end

    # A five-field cron expression, `minute hour day-of-month month
    # day-of-week`, in UTC. Fields take `*`, numbers, ranges `1-5`, steps
    # `*/15` and `10-50/20`, lists `1,15`, and the English three-letter
    # names of months and weekdays (`MON-FRI`, `JAN`); Sunday is 0 or 7.
    # `@hourly`, `@daily`, `@weekly`, `@monthly`, and `@yearly` stand for
    # the usual expressions. When both day fields are restricted, a day
    # matching either runs, as in every cron.
    struct Cron < Schedule
      MONTHS   = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]
      WEEKDAYS = %w[SUN MON TUE WED THU FRI SAT]
      MACROS   = {"@hourly" => "0 * * * *", "@daily" => "0 0 * * *", "@midnight" => "0 0 * * *",
                  "@weekly" => "0 0 * * 0", "@monthly" => "0 0 1 * *", "@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *"}

      getter expression : String

      @minutes : UInt64
      @hours : UInt64
      @days : UInt64
      @months : UInt64
      @weekdays : UInt64
      @any_day : Bool
      @any_weekday : Bool

      # The schedule, or `ArgumentError` naming what is wrong.
      def self.parse(expression : String) : Cron
        new(expression)
      end

      private def initialize(@expression : String)
        fields = (MACROS[@expression.strip]? || @expression).split
        raise ArgumentError.new("cron expression #{@expression.inspect} needs five fields: minute hour day month weekday") unless fields.size == 5
        @minutes = Cron.field(fields[0], 0, 59, "minute")
        @hours = Cron.field(fields[1], 0, 23, "hour")
        @days = Cron.field(fields[2], 1, 31, "day of month")
        @months = Cron.field(fields[3], 1, 12, "month", MONTHS, 1)
        weekdays = Cron.field(fields[4], 0, 7, "weekday", WEEKDAYS, 0)
        # 7 is Sunday too.
        @weekdays = (weekdays | (weekdays >> 7)) & 0x7f_u64
        @any_day = fields[2].starts_with?('*')
        @any_weekday = fields[4].starts_with?('*')
      end

      def next_after(time : Time) : Time?
        time = time.to_utc
        t = Time.utc(time.year, time.month, time.day, time.hour, time.minute) + 1.minute
        limit = t + (5 * 366).days
        while t < limit
          unless bit?(@months, t.month)
            t = Time.utc(t.year, t.month, 1).shift(months: 1)
            next
          end
          unless day?(t)
            t = Time.utc(t.year, t.month, t.day) + 1.day
            next
          end
          unless bit?(@hours, t.hour)
            t = Time.utc(t.year, t.month, t.day, t.hour) + 1.hour
            next
          end
          unless bit?(@minutes, t.minute)
            t += 1.minute
            next
          end
          return t
        end
        nil
      end

      def to_s(io : IO) : Nil
        io << "cron " << @expression
      end

      private def day?(t : Time) : Bool
        day = bit?(@days, t.day)
        weekday = bit?(@weekdays, t.day_of_week.value % 7)
        return day || weekday unless @any_day || @any_weekday

        day && weekday
      end

      private def bit?(mask : UInt64, value : Int32) : Bool
        mask.bit(value) == 1
      end

      # The values one field allows, as bits.
      # :nodoc:
      def self.field(text : String, min : Int32, max : Int32, what : String, names : Array(String)? = nil, offset : Int32 = 0) : UInt64
        mask = 0_u64
        text.split(',').each do |part|
          range, _, step_text = part.partition('/')
          step = step_text.empty? ? 1 : (step_text.to_i? || raise ArgumentError.new("cron #{what}: bad step #{part.inspect}"))
          raise ArgumentError.new("cron #{what}: step must be at least 1 in #{part.inspect}") if step < 1
          first, last = if range == "*"
                          {min, max}
                        elsif range.includes?('-')
                          low, high = range.split('-', 2)
                          {value(low, what, names, offset), value(high, what, names, offset)}
                        else
                          start = value(range, what, names, offset)
                          {start, step_text.empty? ? start : max}
                        end
          unless min <= first <= last <= max
            raise ArgumentError.new("cron #{what}: #{part.inspect} is outside #{min}-#{max}")
          end
          first.step(to: last, by: step) { |number| mask |= 1_u64 << number }
        end
        mask
      end

      private def self.value(text : String, what : String, names : Array(String)?, offset : Int32) : Int32
        if names && (index = names.index(text.upcase))
          return index + offset
        end

        text.to_i? || raise ArgumentError.new("cron #{what}: #{text.inspect} is not a number#{names ? " or a name" : ""}")
      end
    end
  end
end
