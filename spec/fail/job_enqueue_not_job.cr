require "../../src/punch"

struct Export
end

Punch::Job::Queue.enqueue(Export.new)
