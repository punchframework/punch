module Punch::Assets
  # The vendored Turbo (`vendor/turbo/`), written by
  # `scripts/vendor-turbo.sh`; do not edit.
  module Turbo
    VERSION = "8.0.23"
    SHA256  = "b9d35d123a07614f55eaaf993f74d687a503ae41ba50ef835aafa18dbb265a13"
    # The CSP source for the stylesheet of Turbo's progress bar, which Turbo
    # writes into a `<style>` element.
    PROGRESS_BAR_STYLE = "'sha256-WAyOw4V+FqDc35lQPyRADLBWbuNK8ahvYEaQIYF1+Ps='"
  end
end
