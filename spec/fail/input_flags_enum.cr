require "../../src/punch"

@[Flags]
enum Days
  Monday
  Tuesday
end

struct Schedule
  include Punch::Input
  getter days : Days
end

Schedule.from_json("{}")
