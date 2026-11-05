module Punch::CLI::Commands
  # Lists the assets compiled into the application (`Punch.assets`), with
  # their fingerprinted URLs, sizes, the import map, and references in
  # stylesheets that name no asset.
  class Assets < Command
    command "assets", "List the embedded assets with their URLs, and the import map"

    struct Result
      include Report

      def initialize(@table : Punch::Assets::Table)
      end

      def to_text(io : IO) : Nil
        entries = @table.entries.values.sort_by!(&.name)
        width = entries.max_of(&.url.size)
        entries.each do |entry|
          io << entry.url.ljust(width) << "  " << entry.body.bytesize.to_s.rjust(8) << " bytes"
          entry.gzip.try { |gzip| io << "  (gzip " << gzip.bytesize << ')' }
          io.puts
        end
        io.puts
        io.puts "Import map: #{@table.import_map}"
        @table.unresolved.each do |stylesheet, reference|
          io.puts "Unresolved in #{stylesheet}: #{reference}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "assets" do
            json.array do
              @table.entries.values.sort_by!(&.name).each do |entry|
                json.object do
                  json.field "name", entry.name
                  json.field "url", entry.url
                  json.field "content_type", entry.content_type
                  json.field "bytes", entry.body.bytesize
                  json.field "gzip_bytes", entry.gzip.try(&.bytesize)
                end
              end
            end
          end
          json.field "import_map" { json.raw @table.import_map }
          json.field "unresolved" do
            json.array do
              @table.unresolved.each do |stylesheet, reference|
                json.object do
                  json.field "stylesheet", stylesheet
                  json.field "reference", reference
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      no_arguments(args) || Result.new(Punch::Assets.table)
    end
  end
end
