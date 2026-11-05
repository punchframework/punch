require "spec"
require "file_utils"
require "../punch"
require "./json_schema/validator"

# Spec helpers for applications built on Punch: `require "punch/spec"` in
# `spec/spec_helper.cr`.
module Punch::Spec
  # `.should be_invalid("too_long", max: 64)`: a parse failed with this code,
  # and with these params if any are given.
  struct InvalidExpectation
    def initialize(@code : String, @params : Hash(String, Invalid::Param)?)
    end

    def match(actual) : Bool
      actual.is_a?(Invalid) && actual.code == @code && (@params.nil? || actual.params == @params)
    end

    def failure_message(actual) : String
      "Expected: Punch::Invalid #{@code}#{@params.try { |params| " #{params}" }}\n     got: #{actual.inspect}"
    end

    def negative_failure_message(actual) : String
      "Expected anything but Punch::Invalid #{@code}, got: #{actual.inspect}"
    end
  end

  # `.should be_rejected("lines", 0, "amount", code: "blank")`: a rejection
  # holds an error with this code at this path. A violation matches as the
  # rejection it answers with: `be_rejected("email", code: "taken")`.
  struct RejectionExpectation
    def initialize(@path : Rejection::Path, @code : String)
    end

    def match(actual) : Bool
      actual = actual.rejection if actual.is_a?(Database::Violation)
      actual.is_a?(Rejection) && actual.errors.any? { |error| error.path == @path && error.code == @code }
    end

    def failure_message(actual) : String
      "Expected: Punch::Rejection with #{@code} at #{@path}\n     got: #{describe(actual)}"
    end

    def negative_failure_message(actual) : String
      "Expected no #{@code} at #{@path}, got: #{describe(actual)}"
    end

    private def describe(actual) : String
      actual = actual.rejection if actual.is_a?(Database::Violation)
      return actual.inspect unless actual.is_a?(Rejection)

      actual.errors.join(", ") { |error| "#{error.code} at #{error.path}" }
    end
  end
end

module Punch::Spec
  # Builds an input the way a request would, from plain JSON values, and
  # fails the example with every error if it does not parse:
  #
  # ```
  # input = Punch::Spec.input(Send::Input, {"invoice_id" => "42"}, recipient: "ann@example.org")
  # ```
  def self.input(type : T.class, path_params : Hash(String, String) = {} of String => String, **fields) : T forall T
    case result = T.from_json(fields.to_json, path_params)
    in T then result
    in Punch::Rejection
      errors = result.errors.join(", ") { |error| "#{error.code} at #{error.path}" }
      fail "#{T} did not parse: #{errors}"
    end
  end

  # A database for one example, closed and removed afterwards. In memory by
  # default; `file: true` puts it in a fresh directory under the system's
  # temporary directory, for code that depends on WAL or on a second process.
  # That directory must be on local disk. With *schema*, the database starts
  # from that schema file, such as `db/schema.sql`.
  #
  # ```
  # Punch::Spec.database(schema: "db/schema.sql") do |db|
  #   db.write(&.exec("INSERT INTO notes (body) VALUES (?)", "hi"))
  # end
  # ```
  def self.database(*, file : Bool = false, schema : String? = nil,
                    config : Punch::Database::Config = Punch::Database::Config.new(readers: 2), & : Punch::Database ->) : Nil
    directory = file ? File.tempname("punch-spec") : nil
    Dir.mkdir(directory) if directory
    db = directory ? Punch::Database.open(File.join(directory, "spec.db"), config: config) : Punch::Database.memory(config: config)
    begin
      if schema
        Punch::Migrations::Schema.load(db, File.read(schema), schema)
        Punch::Roles.sync(db) if Punch::Roles.used? && Punch::Roles::Schema.present?(db)
      end
      yield db
    ensure
      db.close
      FileUtils.rm_rf(directory) if directory
    end
  end
end

module Punch::Spec
  # Runs the block inside the root span of a fresh trace that records every
  # span, and returns the finished trace:
  #
  # ```
  # trace = Punch::Spec.trace { db.read { |reader| Invoices::Table.find(reader, id) } }
  # trace.should have_span("Billing::Invoices::Table.find", "db.response.returned_rows": 1)
  # trace.root["punch.db.queries"].should eq(1)
  # ```
  def self.trace(name : String = "spec", & : Trace::Span ->) : Trace::Finished
    exporter = Trace::MemoryExporter.new
    tracer = Trace::Tracer.new(exporters: [exporter] of Trace::Exporter, events: [] of Trace::EventSink)
    root = tracer.start(name, :internal)
    begin
      Trace.with(root) { yield root }
    ensure
      root.finish
    end
    exporter.traces.first
  end

  # Retries the block until it passes or *timeout* runs out, then raises
  # its last failure: for effects that happen after a response, such as
  # the wide event.
  def self.eventually(timeout : Time::Span = 2.seconds, & : ->) : Nil
    deadline = Time.instant + timeout
    loop do
      yield
      return
    rescue ex : ::Spec::AssertionFailed
      raise ex if Time.instant >= deadline
      sleep 5.milliseconds
    end
  end

  # `.should have_span("name", key: value)`: the trace holds a span with
  # this name and at least these attributes.
  struct SpanExpectation
    def initialize(@name : String, @attributes : Hash(String, Trace::Value))
    end

    def match(actual : Trace::Finished) : Bool
      !!find(actual)
    end

    def failure_message(actual : Trace::Finished) : String
      "Expected a span #{@name}#{@attributes.empty? ? "" : " with #{@attributes}"}\n     got: #{describe(actual)}"
    end

    def negative_failure_message(actual : Trace::Finished) : String
      "Expected no span #{@name}#{@attributes.empty? ? "" : " with #{@attributes}"}, got: #{describe(actual)}"
    end

    private def find(trace : Trace::Finished) : Trace::Span?
      found = nil
      trace.each_span do |span|
        next unless span.name == @name
        attributes = span.attributes
        found ||= span if @attributes.all? { |key, value| attributes[key]? == value }
      end
      found
    end

    private def describe(trace : Trace::Finished) : String
      names = [] of String
      trace.each_span { |span| names << "#{span.name} #{span.attributes}" }
      names.join("\n          ")
    end
  end
end

module Punch::Spec
  # `.should match_schema(schema, root: document)`: the JSON value is valid
  # against the schema; the failure lists every violation.
  struct SchemaExpectation
    def initialize(@schema : JSON::Any, @root : JSON::Any)
    end

    def match(actual : JSON::Any) : Bool
      JSONSchema.validate(actual, @schema, @root).empty?
    end

    def failure_message(actual : JSON::Any) : String
      violations = JSONSchema.validate(actual, @schema, @root)
      "Expected #{actual.to_json} to match the schema:\n  #{violations.join("\n  ")}"
    end

    def negative_failure_message(actual : JSON::Any) : String
      "Expected #{actual.to_json} not to match the schema #{@schema.to_json}"
    end
  end
end

module Punch::Spec
  # `.should be_encrypted_for("customers", "address")`: a value read
  # straight from the database is ciphertext that this column's key opens.
  # The messages never show the plaintext.
  struct EncryptedExpectation
    def initialize(@table : String, @column : String)
    end

    def match(actual : Bytes?) : Bool
      !!actual.try { |raw| Stored.encryptor(@table, @column).decrypt(raw) }
    end

    def failure_message(actual : Bytes?) : String
      actual ? "Expected ciphertext of #{@table}.#{@column}, got #{actual.size} bytes its key does not open" : "Expected ciphertext of #{@table}.#{@column}, got NULL"
    end

    def negative_failure_message(actual : Bytes?) : String
      "Expected anything but ciphertext of #{@table}.#{@column}, got a value its key opens"
    end
  end
end

module Spec::Expectations
  def be_encrypted_for(table : String, column : String)
    Punch::Spec::EncryptedExpectation.new(table, column)
  end

  def match_schema(schema : JSON::Any, root : JSON::Any = schema)
    Punch::Spec::SchemaExpectation.new(schema, root)
  end

  def have_span(name : String, **attributes)
    hash = {} of String => Punch::Trace::Value
    attributes.each { |key, value| hash[key.to_s] = value.is_a?(Int32) ? value.to_i64 : value }
    Punch::Spec::SpanExpectation.new(name, hash)
  end

  def be_invalid(code : String, **params)
    hash = params.empty? ? nil : Punch::Invalid.new(code, **params).params
    Punch::Spec::InvalidExpectation.new(code, hash)
  end

  def be_rejected(*path : String | Int32, code : String)
    Punch::Spec::RejectionExpectation.new(Punch::Rejection::Path.new.concat(path), code)
  end

  # An error on the input as a whole, from a cross-field rule.
  def be_rejected(*, code : String)
    Punch::Spec::RejectionExpectation.new(Punch::Rejection::Path.new, code)
  end
end

require "./spec/database"
require "./spec/metrics"
require "./spec/client"
require "./spec/schema"
require "./spec/round_trip"
require "./spec/credentials"
require "./spec/auth"
require "./spec/html"
require "./spec/actions"
require "./spec/cache"
require "./spec/clock"
require "./spec/rate_limits"
require "./spec/idempotency"
require "./spec/webhooks"
require "./spec/events"
require "./spec/jobs"
require "./spec/ops"
require "./spec/mail"
require "./spec/live"
require "./spec/uploads"
