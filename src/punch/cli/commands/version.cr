module Punch::CLI::Commands
  class Version < Command
    command "version", "Print the Punch, Crystal, SQLite, and OpenSSL versions"

    struct Result
      include Report

      def to_text(io : IO) : Nil
        io.puts "punch #{Punch::VERSION} (Crystal #{Crystal::VERSION}, SQLite #{Punch::Database::Driver.version}, OpenSSL #{LibCrypto::OPENSSL_VERSION})"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "punch", Punch::VERSION
          json.field "crystal", Crystal::VERSION
          # What a security release of either would need a rebuild for.
          json.field "sqlite", Punch::Database::Driver.version
          json.field "openssl", LibCrypto::OPENSSL_VERSION
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      no_arguments(args) || Result.new
    end
  end
end
