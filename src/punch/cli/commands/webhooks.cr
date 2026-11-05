module Punch::CLI::Commands
  # Lists the inbound webhook providers of the application it is compiled
  # into: name, endpoint, how each verifies, and how many invocations each
  # has per state in `primary.db`, when there is one.
  class Webhooks < Command
    command "webhooks", "List the inbound webhook providers, how they verify, and their invocations per state"

    record Provider, name : String, type : String, verify : String, counts : Hash(String, Int64)

    struct Result
      include Report

      def initialize(@providers : Array(Provider), @database : String?)
      end

      def to_text(io : IO) : Nil
        return io.puts("No webhook providers.") if @providers.empty?

        @providers.each do |provider|
          io << provider.name << "  POST /webhooks/" << provider.name << "  " << provider.type << "  verify: " << provider.verify
          io << "  (does not verify: anyone can post to it)" if provider.verify == "none"
          io << '\n'
          next if provider.counts.empty?
          io << "  " << provider.counts.join(", ") { |state, count| "#{count} #{state}" } << '\n'
        end
        io.puts "(no #{@database}: counts need the database)" if @database
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "providers" do
            json.array do
              @providers.each do |provider|
                json.object do
                  json.field "name", provider.name
                  json.field "path", "/webhooks/#{provider.name}"
                  json.field "type", provider.type
                  json.field "verify", provider.verify
                  json.field "counts", provider.counts
                end
              end
            end
          end
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      if failure = no_arguments(args)
        return failure
      end

      counts = {} of String => Hash(String, Int64)
      missing = nil.as(String?)
      unless Punch::Webhook.providers.empty?
        settings = Config.settings
        return settings if settings.is_a?(Failure)

        path = settings.primary_database
        if File.exists?(path)
          database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1))
          begin
            if Punch::Webhook::Invocations.problems(database).empty?
              database.read { |db| Punch::Webhook::Invocations.counts(db) }.each do |provider, state, count|
                (counts[provider] ||= {} of String => Int64)[state] = count
              end
            end
          ensure
            database.close
          end
        else
          missing = path
        end
      end
      providers = Punch::Webhook.providers.map do |name, type, verify|
        Provider.new(name, type, verify, counts[name]? || {} of String => Int64)
      end
      Result.new(providers, missing)
    rescue ex : Punch::Database::Error | Punch::Database::FilesystemError
      Failure.new("database_error", ex.message || "database error")
    end
  end
end
