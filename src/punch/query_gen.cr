require "./query_gen/model"
require "./query_gen/sql"
require "./query_gen/composites"
require "./query_gen/primitives"
require "./query_gen/schema"
require "./query_gen/mapping"
require "./query_gen/groups"
require "./query_gen/paths"
require "./query_gen/query_file"
require "./query_gen/writes"
require "./query_gen/clauses"
require "./query_gen/keyset"
require "./query_gen/analyzer"
require "./query_gen/explain"
require "./query_gen/emitter"
require "./query_gen/composite_emitter"

module Punch
  # The query generator behind `punch db:generate` (the sqlc model). It
  # loads `db/schema.sql` into the SQLite every Punch binary links, applies
  # the column mappings of every `columns.cr` under `app/` and `src/`,
  # prepares every named query, and writes typed Crystal:
  #
  # - next to each `columns.cr`, `records.gen.cr`: for each table it maps
  #   a `Record` and a `Table` module with `find`, `insert`, `update`, and
  #   `delete`. Each record's comment names its behaviour file
  #   (`behaviour_file`);
  # - next to each query file, `<name>.gen.cr`: one method per query, with a
  #   `Row` for queries that do not select a whole record.
  #
  # Not part of `require "punch"`: applications never load the generator.
  module QueryGen
    record Output, path : String, content : String

    # The outcome of a run: every file to write, and what was analyzed, for
    # the report.
    record Result, outputs : Array(Output), analyses : Array(Analysis), schema : Schema,
      plans : Array(Explain::Report) = [] of Explain::Report

    record Config,
      schema : String = Migrations::SCHEMA,
      mappings : Array(String) = QueryGen.mapping_files,
      queries : Array(String) = [] of String,
      composites : Array(String) = Composites.files,
      app_dir : String = "app",
      explain : Bool = false

    # Generates everything, or raises `Errors` with every mistake found.
    # Without a `columns.cr`, no table is mapped.
    def self.run(config : Config) : Result
      errors = [] of Error
      database = Database.memory(name: "generate", config: Database::Config.new(readers: 1))
      begin
        begin
          Punch::Migrations::Schema.load(database, File.read(config.schema), config.schema)
        rescue ex : Migrations::Error
          raise Errors.new([Error.new(Location.new(config.schema, 1), ex.message || "the schema does not load")])
        end
        schema = Schema.new(database)
        schema.composites = Composites.collect(config.composites + config.mappings, errors)
        schema.primitives = Primitives.new
        modules = {} of String => String
        config.mappings.each { |path| errors.concat(Mapping.apply(schema, File.read(path), path, modules)) }
        Paths.type_generated(schema, config.schema, errors)
        schema.tables.each_value { |table| table.behaviour = table.mod.try { |mod| behaviour_file(mod, config.app_dir) } }
        check_records(schema, errors)
        name_violations(schema)
        check_triggers(schema, config.schema, errors)

        files = config.queries.map do |path|
          {path, QueryFile.parse(File.read(path), path, errors)}
        end
        analyses = [] of Analysis
        outputs = [] of Output
        plans = [] of Explain::Report
        database.with_writer_connection do |connection|
          files.each do |path, queries|
            mod = module_name(path, errors)
            done = queries.compact_map { |query| Analyzer.new(schema, query, errors).analyze(connection) }
            analyses.concat(done)
            outputs << Output.new(output_path(path), Emitter.queries(mod, done, schema, path)) if mod
          end
          plans = analyses.map { |analysis| Explain.report(connection, analysis, schema) } if config.explain
        end
        raise Errors.new(errors) unless errors.empty?

        used = analyses.flat_map(&.violations).to_set
        mapped = schema.tables.each_value.select(&.mod).group_by { |table| table.mapped_in || "" }
        declared = schema.composites.each_value.group_by(&.file)
        records = (mapped.keys + config.mappings.select { |path| declared.has_key?(path) }).uniq.sort!.map do |mapping|
          tables = mapped[mapping]? || [] of Schema::Table
          sources = tables.empty? ? mapping : "#{config.schema} and #{mapping}"
          Output.new(records_path(mapping), Emitter.records(schema, tables, sources, used, declared[mapping]? || [] of Composite))
        end
        composites = config.composites.select { |path| declared.has_key?(path) }.map do |path|
          Output.new(File.join(File.dirname(path), "composites.gen.cr"), Emitter.composite_file(schema, declared[path], path))
        end
        outputs = composites + records + outputs
        formatted = outputs.map { |output| Output.new(output.path, Emitter.format(output.content, output.path)) }
        Result.new(formatted, analyses, schema, plans)
      ensure
        database.close
      end
    end

    # Punch's own composites, for `punch db:generate` in Punch itself,
    # which has no schema.
    def self.own_composites : Result
      database = Database.memory(name: "generate", config: Database::Config.new(readers: 1))
      begin
        errors = [] of Error
        schema = Schema.new(database)
        schema.composites = Composites.collect([Composites::OWN_PATH], errors)
        raise Errors.new(errors) unless errors.empty?

        path = File.join(File.dirname(Composites::OWN_PATH), "composites.gen.cr")
        content = Emitter.composite_file(schema, schema.composites.values, Composites::OWN_PATH)
        Result.new([Output.new(path, Emitter.format(content, path))], [] of Analysis, schema)
      ensure
        database.close
      end
    end

    # The query files of an app: every `.sql` file under `app/` and `src/`.
    def self.query_files(root : String = ".") : Array(String)
      Dir.glob("#{root}/{app,src}/**/*.sql").map { |path| ::Path[path].relative_to(root).to_s }.sort!
    end

    # The column mappings of an app: every `columns.cr` under `app/` and
    # `src/`, each beside the entity whose tables it maps.
    def self.mapping_files(root : String = ".") : Array(String)
      Dir.glob("#{root}/{app,src}/**/columns.cr").map { |path| ::Path[path].relative_to(root).to_s }.sort!
    end

    # The namespace a file under `app/` or `src/` belongs to, from its
    # directories: `Billing::Invoices` for `app/billing/invoices/columns.cr`,
    # `nil` directly in `app/` or outside both.
    def self.namespace(path : String) : String?
      parts = ::Path[path].parts
      root = parts.rindex(&.in?("app", "src")) || return
      names = parts[(root + 1)...-1]
      names.join("::") { |name| camelcase(name) } unless names.empty?
    end

    # The generated records of the tables *mapping* maps, beside it.
    def self.records_path(mapping : String) : String
      File.join(File.dirname(mapping), "records.gen.cr")
    end

    # Where an app's code lives: `app/`, or `src/` when it has only that.
    def self.app_dir(root : String = ".") : String
      !Dir.exists?(File.join(root, "app")) && Dir.exists?(File.join(root, "src")) ? "src" : "app"
    end

    # The behaviour file of the record in *mod*, named like any Crystal
    # type's file: `Billing::Customers::Record` reopens in
    # `app/billing/customers/record.cr`.
    def self.behaviour_file(mod : String, app_dir : String = "app") : String
      File.join([app_dir] + mod.split("::").map { |name| underscore(name) } + ["record.cr"])
    end

    def self.output_path(path : String) : String
      "#{path.rchop(File.extname(path))}.gen.cr"
    end

    # `app/billing/invoices/queries.sql` holds `Billing::Invoices::Queries`.
    def self.module_name(path : String, errors : Array(Error)) : String?
      parts = ::Path[path].parts
      root = parts.rindex(&.in?("app", "src"))
      unless root
        errors << Error.new(Location.new(path, 1), "query files live under app/ or src/, which gives their module (app/billing/queries.sql holds Billing::Queries)")
        return
      end
      names = parts[(root + 1)...-1] + [File.basename(path, File.extname(path))]
      unless names.all?(&.matches?(/\A[a-z][a-z0-9_]*\z/))
        errors << Error.new(Location.new(path, 1), "directory and file names of query files must be snake_case, to give a module name")
        return
      end
      names.join("::") { |name| camelcase(name) }
    end

    # Names the violation struct of each unique constraint of a mapped
    # table after the columns that are not foreign keys, `EmailTaken` for
    # `customers.email` and `PositionTaken` for `(invoice_id, position)`,
    # and gives it a field when that is one column. Names that would clash
    # use every key column, and then the index's name. A blind index stands
    # for its encrypted column: `EmailTaken` for `(organization_id,
    # email_index)`, at the field `email`.
    private def self.name_violations(schema : Schema) : Nil
      schema.tables.each_value do |table|
        next unless table.mod
        table.uniques.each do |unique|
          next if unique.trigger? # named by its Punch.violation
          keys = (unique.columns.empty? ? unique.referenced : unique.columns).map { |name| table.column(name).try(&.source) || name }
          own = keys.reject { |name| table.foreign_keys.includes?(name) }
          own = keys if own.empty?
          unique.field = own.size == 1 ? own.first : nil
          unique.type_name = own.empty? ? "#{camelcase(unique.name)}Taken" : "#{camelcase(own.join('_'))}Taken"
        end
        clashing = table.uniques.reject(&.trigger?).group_by(&.type_name).values.select(&.size.>(1)).flatten
        clashing.each do |unique|
          keys = unique.columns.empty? ? unique.referenced : unique.columns
          unique.type_name = "#{camelcase(keys.join('_'))}Taken" unless keys.empty?
        end
        clashing = table.uniques.reject(&.trigger?).group_by(&.type_name).values.select(&.size.>(1)).flatten
        clashing.each { |unique| unique.type_name = "#{camelcase(unique.name)}Taken" }
      end
    end

    # Every Punch code a trigger on a mapped table raises is declared
    # (`Punch.violation`), and raised so that it can be a value: with
    # `RAISE(ABORT, …)`. On other tables it stays an exception, as their
    # unique violations do.
    private def self.check_triggers(schema : Schema, path : String, errors : Array(Error)) : Nil
      text = File.read(path)
      schema.triggers.each do |trigger|
        next unless schema.table(trigger.table).try(&.mod)
        location = Location.new(path, text.byte_index("TRIGGER #{trigger.name}").try { |offset| text.byte_slice(0, offset).count('\n') + 1 } || 1)
        trigger.refused.each do |code|
          errors << Error.new(location, "trigger #{trigger.name} raises 'punch:#{code}' with ROLLBACK, FAIL, or IGNORE; a Punch code needs RAISE(ABORT, 'punch:#{code}'), which rolls back only the statement")
        end
        declared = schema.table(trigger.table).try(&.uniques.compact_map(&.code)) || [] of String
        (trigger.codes - declared).uniq.each do |code|
          errors << Error.new(location, "trigger #{trigger.name} raises 'punch:#{code}', which no Punch.violation declares; declare it in the columns.cr that maps #{trigger.table}: Punch.violation \"#{code}\", Type, status: 409")
        end
      end
    end

    # A mapped table gets a record: its declared types must be enforced
    # (STRICT), and its columns become getters, so each needs a Crystal
    # name.
    private def self.check_records(schema : Schema, errors : Array(Error)) : Nil
      schema.tables.each_value do |table|
        location = table.mapped_at || next
        unless table.strict?
          errors << Error.new(location, "#{table.name} is not STRICT, so SQLite does not enforce its column types; only STRICT tables can be mapped")
        end
        table.columns.each do |column|
          unless identifier?(column.name)
            errors << Error.new(location, "#{table.name}.#{column.name} is not a Crystal name, so #{table.name} cannot have a record; rename the column")
          end
          unless column.type
            errors << Error.new(location, "#{table.name}.#{column.name} is declared #{column.declared.empty? ? "without a type" : column.declared}; a mapped table needs INTEGER, REAL, TEXT, or BLOB columns")
          end
        end
      end
    end
  end
end
