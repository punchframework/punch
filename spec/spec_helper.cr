require "spec"
require "../src/punch"
require "../src/punch/spec"

# Specs run with parallelism greater than one.
# CRYSTAL_WORKERS sets the thread count; it defaults to the number of CPUs.
Fiber::ExecutionContext.default.resize(
  maximum: Fiber::ExecutionContext.default_workers_count)
