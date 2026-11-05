require "compiler/crystal/syntax"
require "./requires_gen"
require "./bareknuckle/fingerprint"
require "./bareknuckle/inputs"
require "./bareknuckle/stats"
require "./bareknuckle/round_log"
require "./bareknuckle/daemon"

module Punch
  # Incremental builds for `punch dev` and `punch typecheck`: what each
  # round rebuilds and what a warm compiler would have needed, measured; and
  # builds with the daemon (`src/bareknuckle/`, its own binary), which keeps
  # the typed program warm and builds method body edits on a fast path
  # (`Daemon`). Part of the standalone `punch` tool only, like the
  # generators, since it uses Crystal's parser.
  module Bareknuckle
  end
end
