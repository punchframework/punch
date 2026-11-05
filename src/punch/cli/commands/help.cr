module Punch::CLI::Commands
  class Help < Command
    command "help", "List commands"

    struct Result
      include Report

      def initialize(@commands : Array(Command.class))
      end

      def to_text(io : IO) : Nil
        io.puts "Usage: #{CLI.program} <command> [arguments] [--json]"
        io.puts
        io.puts "Commands:"
        width = @commands.max_of(&.command_name.size)
        @commands.each do |command|
          io.puts "  #{command.command_name.ljust(width)}  #{command.summary}"
        end
        io.puts
        io.puts "--json writes one JSON document to stdout, also on failure."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "commands" do
            json.array do
              @commands.each do |command|
                json.object do
                  json.field "name", command.command_name
                  json.field "summary", command.summary
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      no_arguments(args) || Result.new(commands)
    end
  end
end
