module Punch
  # The databases of one application, each its own file with its own writer:
  # `primary` for the app's data, and later `queue`, `cache`, and `ops`. All
  # files live in one directory, which is checked at boot.
  #
  # ```
  # databases = Punch::Databases.open("/var/lib/app", %w[primary queue])
  # databases.attach(server) # health checks, and closing after the drain
  # router = Punch::Routing::Router.new(databases.primary)
  # ```
  class Databases
    getter directory : String

    @databases : Hash(String, Database)

    # Opens `<name>.db` in *directory* for each of *names*. Refuses a
    # directory on a network or virtual filesystem before opening anything.
    def self.open(directory : String, names : Enumerable(String) = {"primary"},
                  config : Database::Config = Database::Config.new) : self
      Database::Filesystem.check!(File.join(directory, "check.db"))
      databases = {} of String => Database
      begin
        names.each do |name|
          raise ArgumentError.new("invalid database name: #{name.inspect}") unless name.matches?(/\A[a-z][a-z0-9_]*\z/)
          databases[name] = Database.open(File.join(directory, "#{name}.db"), name: name, config: config)
        end
      rescue ex
        databases.each_value(&.close)
        raise ex
      end
      new(directory, databases)
    end

    # In-memory databases with the same names, for specs.
    def self.memory(names : Enumerable(String) = {"primary"}, config : Database::Config = Database::Config.new) : self
      new("(memory)", names.to_h { |name| {name, Database.memory(name: name, config: config)} })
    end

    protected def initialize(@directory : String, @databases : Hash(String, Database))
    end

    def [](name : String) : Database
      @databases[name]? || raise KeyError.new("no database #{name}; open: #{names.join(", ")}")
    end

    def primary : Database
      self["primary"]
    end

    def names : Array(String)
      @databases.keys
    end

    def each(& : Database ->) : Nil
      @databases.each_value { |database| yield database }
    end

    # Closes every database, in the reverse order of opening.
    def close : Nil
      @databases.values.reverse_each(&.close)
    end

    # Registers every database's signals with *registry* (`docs/metrics.md`).
    def observe(registry : Metrics::Registry = Metrics.registry) : Nil
      each(&.observe(registry))
    end

    # Adds a health check per database to *server*, and closes the databases
    # once requests have drained.
    def attach(server : HTTP::Server) : Nil
      each do |database|
        server.health_check("database:#{database.name}") { database.health }
      end
      server.on_shutdown("databases") { close }
    end
  end
end
