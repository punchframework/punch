module Punch
  # What only a `punch dev` build (`-Dpunch_dev`) has: a reload stream that
  # makes an open page reload itself when the app was restarted with new
  # code or one of its assets changed (`docs/tooling.md`, "`punch dev`").
  #
  # Every document loads `SCRIPT` (`View#document`), an asset like any
  # other, so the Content-Security-Policy needs nothing more. It opens an
  # `EventSource` on `PATH`, which the HTTP kernel answers itself, untraced
  # like `/up`.
  module Dev
    PATH = "/punch/dev/reload"

    SCRIPT = "punch/dev_reload.js"

    SCRIPT_SOURCE = <<-JS
      // punch dev: reloads the page when an asset changed, or when the app
      // was restarted (the stream opens again).
      let opened = false
      const source = new EventSource("#{PATH}")
      source.addEventListener("open", () => { if (opened) location.reload(); opened = true })
      source.addEventListener("reload", () => location.reload())
      JS

    # How often the stream looks at the assets, and how often it sends a
    # comment to keep the connection open.
    TICK      = 250.milliseconds
    KEEPALIVE = 15.seconds

    # Writes the stream on *io* until the client goes away or *ending*
    # says the server is shutting down: a `reload` event whenever *version*
    # changes (by default `Assets.version`, after a look at the files).
    def self.stream(io : IO, ending : -> Bool, version source : -> Int32 = -> { Assets.table; Assets.version }, tick : Time::Span = TICK) : Nil
      # Reconnect soon after a restart, so the page reloads quickly.
      io << "retry: 250\n\n"
      io.flush
      version = source.call
      quiet = Time::Span.zero
      until ending.call
        sleep tick
        current = source.call
        if current != version
          version = current
          io << "event: reload\ndata: assets\n\n"
          io.flush
          quiet = Time::Span.zero
        elsif (quiet += tick) >= KEEPALIVE
          io << ":\n\n"
          io.flush
          quiet = Time::Span.zero
        end
      end
    rescue IO::Error
      # The client went away.
    end
  end
end
