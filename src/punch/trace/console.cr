require "colorize"

module Punch::Trace
  # Prints each trace as an indented tree, for development:
  #
  # ```text
  # GET /billing/invoices/:invoice_id 200 shown  1.84 ms  trace 4bf92f3577b34da6…
  #    +0.02    0.01 ms  input
  #    +0.04    1.10 ms  primary read
  #    +0.09    0.42 ms    Billing::Queries.invoice_by_id rows=1
  # ```
  #
  # Each line shows the start relative to the root, the duration, and the
  # name, indented by depth, with the attributes that matter while reading
  # a trace. Writes once per trace, so traces of parallel requests do not
  # interleave.
  class ConsoleExporter < Exporter
    # Attributes worth showing on a line, with their short label.
    DETAILS = {
      "db.response.returned_rows" => "rows",
      "punch.db.changes"          => "changes",
      "punch.db.writer_wait_ms"   => "wait_ms",
      "punch.input.errors"        => "errors",
      "exception.type"            => "exception",
    }

    @lock = Mutex.new
    @color : Bool

    # Colors only on a terminal unless *color* says otherwise.
    def initialize(@io : IO = STDERR, color : Bool? = nil)
      @color = color.nil? ? @io.tty? : color
    end

    def export(trace : Finished) : Nil
      text = String.build { |io| render(io, trace) }
      @lock.synchronize do
        @io << text
        @io.flush
      end
    end

    private def render(io : IO, trace : Finished) : Nil
      root = trace.root
      attributes = root.attributes
      io << paint(root.name, :bold)
      attributes["http.response.status_code"]?.try { |status| io << ' ' << paint(status.to_s, status.as?(Int64).try { |code| code >= 500 } ? :red : :green) }
      attributes["punch.outcome"]?.try { |outcome| io << ' ' << outcome }
      io << "  " << milliseconds(root.duration)
      attributes["punch.db.queries"]?.try { |count| io << "  queries " << count }
      io << "  trace " << paint(root.trace_id.to_s, :dark_gray) << '\n'

      children = trace.spans.group_by(&.parent_id)
      tree(io, children, root, 1)
      if root.status.error?
        io << "   " << paint("error: #{root.status_message}", :red) << '\n'
      end
    end

    private def tree(io : IO, children : Hash(SpanID?, Array(Span)), parent : Span, depth : Int32) : Nil
      (children[parent.span_id]? || return).sort_by(&.started).each do |span|
        offset = (span.started - parent.root.started).total_milliseconds
        io << ("+%.2f" % offset).rjust(9) << ' ' << milliseconds(span.duration).rjust(10) << "  " << "  " * (depth - 1)
        io << paint(span.name, span.status.error? ? :red : :default)
        attributes = span.attributes
        DETAILS.each do |key, label|
          attributes[key]?.try { |value| io << ' ' << label << '=' << value }
        end
        io << '\n'
        tree(io, children, span, depth + 1)
      end
    end

    private def milliseconds(duration : Time::Span?) : String
      duration ? "%.2f ms" % duration.total_milliseconds : "unfinished"
    end

    private def paint(text : String, color : Symbol) : String
      return text unless @color

      case color
      when :bold      then text.colorize.bold.to_s
      when :red       then text.colorize(:red).to_s
      when :green     then text.colorize(:green).to_s
      when :dark_gray then text.colorize(:dark_gray).to_s
      else                 text
      end
    end
  end
end
