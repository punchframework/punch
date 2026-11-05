module Punch::Bareknuckle
  # What `crystal build --stats` printed: each stage's time and the heap
  # after it, and which LLVM modules the object cache could not reuse
  # (the oracle for a predicted dirty set).
  struct Stats
    record Stage, name : String, seconds : Float64, heap_mb : Float64

    STAGE = /^([A-Z][^:\n]*?):\s+(\d+):(\d+):(\d+(?:\.\d+)?)\s+\(\s*([\d.]+)MB\)/m
    SOME  = /^ - (\d+)\/(\d+) \.o files were reused/m

    getter stages = [] of Stage
    # Modules reused and in all; `nil` when the compiler did not say
    # (all or none reused, or no code generated).
    getter reused : Int32? = nil
    getter total : Int32? = nil
    # `all`, `none`, `some`, or `nil` without code generation.
    getter reuse : String? = nil
    # The modules regenerated, when only some were.
    getter rebuilt = [] of String

    def self.parse(output : String) : Stats
      stats = new
      # The progress display rewrites lines with carriage returns.
      text = output.gsub(/[^\n]*\r/, "")
      text.scan(STAGE) do |match|
        seconds = match[2].to_i * 3600 + match[3].to_i * 60 + match[4].to_f
        stats.stages << Stage.new(match[1], seconds, match[5].to_f)
      end
      stats.read_modules(text)
      stats
    end

    protected def read_modules(text : String) : Nil
      if text.includes?(" - all previous .o files were reused")
        @reuse = "all"
      elsif text.includes?(" - no previous .o files were reused")
        @reuse = "none"
      elsif match = text.match(SOME)
        @reuse = "some"
        @reused = match[1].to_i
        @total = match[2].to_i
        if list = text.split("These modules were not reused:\n", 2)[1]?
          list.each_line do |line|
            break unless line.starts_with?(" - ")
            @rebuilt << line.lchop(" - ").sub(/ \([^)]*\.bc\)$/, "")
          end
        end
      end
    end

    # *output* without what `--stats` adds, for showing a failed build:
    # the progress display, stage lines, and the macro run and module
    # reports.
    def self.strip(output : String) : String
      text = output.gsub(/[^\n]*\r/, "")
      text = text.sub(/^\n?Macro runs:\n( - [^\n]*\n)*/m, "").sub(/^\n?Codegen \(bc\+obj\):\n( - [^\n]*\n?|\n|These modules were not reused:\n)*/m, "")
      text.lines.reject(&.matches?(STAGE)).join("\n").strip
    end

    # The seconds of the stages whose names start with *prefix*.
    def seconds(prefix : String) : Float64
      stages.select(&.name.starts_with?(prefix)).sum(&.seconds)
    end

    # The largest heap after any stage.
    def peak_mb : Float64
      stages.max_of?(&.heap_mb) || 0.0
    end

    # Stage times in four groups: typing, IR generation, bitcode and
    # objects, linking.
    def groups : Hash(String, Float64)
      {
        "typing"  => seconds("Parse") + seconds("Semantic"),
        "ir"      => seconds("Codegen (crystal)"),
        "objects" => seconds("Codegen (bc+obj)"),
        "link"    => seconds("Codegen (linking)"),
      }
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "groups" { json.object { groups.each { |name, value| json.field name, value.round(3) } } }
        json.field "stages" { json.object { stages.each { |stage| json.field stage.name, stage.seconds.round(3) } } }
        json.field "peak_mb", peak_mb.round
        json.field "reuse", reuse
        json.field "reused", reused
        json.field "total", total
        json.field "rebuilt", rebuilt
      end
    end
  end
end
