require "json"
require "option_parser"
require "./compiler"
require "./sources"
require "./hooks"
require "../punch/bareknuckle/fingerprint"
require "./program_map"
require "./typing"
require "./prediction"
require "./emit"
require "./index"
require "./changes"
require "./warm"
require "./verification"
require "./daemon"

# `bareknuckle`, the incremental compiler behind `punch dev`. Built from
# Crystal's compiler sources by `punch bareknuckle:build`, separately from
# the `punch` tool, since it links LLVM and the whole compiler.
#
# - `bareknuckle version`: the Crystal release it is built from, as JSON.
# - `bareknuckle serve --main FILE --output FILE --socket PATH
#   [--link-flags FLAGS] [-D FLAG…]`: the warm compiler
#   (`Bareknuckle::Daemon`), run from the app's root.
# - `bareknuckle build --main FILE --output FILE [--link-flags FLAGS]
#   [-D FLAG…]`: a full build, as `crystal build --stats`, with this
#   binary's compiler and LLVM.
# - `bareknuckle type --main FILE [-D FLAG…]`: types the app and prints
#   its map (`Bareknuckle::Typing`), as JSON.
# - `bareknuckle map --main FILE [-D FLAG…] [--file PATH]`: types the app
#   once and prints a summary of its map, as JSON; with `--file`, each
#   function whose code comes from that file, one per line.
module Bareknuckle
  # The Crystal release whose compiler this binary is built from: it types
  # programs exactly like that release only, and its hooks (`hooks.cr`)
  # copy that release's methods.
  CRYSTAL = Crystal::Config.version

  def self.main(args : Array(String)) : Int32
    command = args.shift?
    main = socket = file = output = link_flags = nil
    flags = [] of String
    OptionParser.parse(args) do |parser|
      parser.on("--main FILE", "") { |value| main = value }
      parser.on("--socket PATH", "") { |value| socket = value }
      parser.on("--output FILE", "") { |value| output = value }
      parser.on("--link-flags FLAGS", "") { |value| link_flags = value }
      parser.on("-D FLAG", "") { |value| flags << value }
      parser.on("--file PATH", "") { |value| file = File.expand_path(value) }
    end
    Sources.root = "#{Dir.current}/"
    return version if command == "version"

    run(command, main.try { |path| File.expand_path(path) }, flags, output.try { |path| File.expand_path(path) }, link_flags, socket, file)
  rescue ex : Crystal::CodeError
    STDERR.puts ex.message
    1
  rescue ex : Crystal::Error
    STDERR.puts "Error: #{ex.message}"
    1
  end

  private def self.run(command : String?, main_file : String?, flags : Array(String), output_file : String?, link : String?,
                       socket_path : String?, file : String?) : Int32
    case command
    when "serve"
      return usage unless main_file && socket_path && output_file

      Daemon.new(main_file, flags, output_file, link, socket_path, "#{socket_path}.out").run
    when "build"
      return usage unless main_file && output_file

      # A plain full build with this binary's compiler, as `punch dev`'s
      # verification build: the object cache must come from the same LLVM
      # as the daemon's to compare.
      warm = Warm.build(main_file, flags, output_file, link)
      warm.compiler.warnings.report(STDERR)
    when "type"
      return usage unless main_file

      # `Typing#apart`: the overlay on standard input, the result on
      # standard output.
      overlay = Hash(String, String).from_json(STDIN.gets_to_end)
      Typing.new(main_file, flags).run(overlay).to_json(STDOUT)
    when "map"
      return usage unless main_file

      map(Typing.new(main_file, flags).run({} of String => String), file)
    else
      return usage
    end
    0
  end

  private def self.version : Int32
    puts({crystal: CRYSTAL, llvm: LibLLVM::VERSION}.to_json)
    0
  end

  private def self.usage : Int32
    STDERR.puts "usage: bareknuckle version | build --main FILE --output FILE [--link-flags FLAGS] [-D FLAG…] | serve --main FILE --output FILE --socket PATH [--link-flags FLAGS] [-D FLAG…] | type --main FILE [-D FLAG…] | map --main FILE [-D FLAG…] [--file PATH]"
    2
  end

  # What the daemon would hold after *typed*, as JSON; with *file*, each
  # function with code from it, one per line.
  private def self.map(typed : Typing::Result, file : String?) : Nil
    if file
      typed.map.functions.each_value do |function|
        lines = function.origins.select { |(path, _, _)| path == file }.map(&.[1]).sort!
        puts({key: function.key, module: function.module_name, lines: lines}.to_json) unless lines.empty?
      end
      return
    end
    puts({
      typing_seconds: typed.seconds.round(2), map_seconds: typed.walk_seconds.round(2),
      functions: typed.map.functions.size, modules: typed.map.modules.keys.sort!,
      files: typed.files.keys.sort!, macro_files: typed.macro_files.to_a.sort!, macro_commands: typed.macro_commands.to_a.sort!,
    }.to_json)
  end
end

exit Bareknuckle.main(ARGV.dup)
