require "compiler/crystal/syntax"

module Punch::QueryGen
  # Reads a `columns.cr` with Crystal's own parser, without compiling the
  # app, and applies it to the schema. The file holds only `Punch.table`
  # and `Punch.violation` calls (and requires and comments); everything
  # else is an error here, so
  # the generator never has to guess what the compiler will see. It maps
  # only tables whose module is in its own namespace
  # (`app/billing/invoices/columns.cr` maps `Billing::Invoices` and
  # `Billing::Invoices::Lines`), so an entity's tables are mapped beside
  # it. *modules* collects the modules of every mapping file, which must
  # differ.
  module Mapping
    def self.apply(schema : Schema, source : String, file : String, modules : Hash(String, String) = {} of String => String) : Array(Error)
      errors = [] of Error
      begin
        root = Crystal::Parser.parse(source)
      rescue ex : Crystal::SyntaxException
        return [Error.new(Location.new(file, ex.line_number, ex.column_number), "#{ex.message}")]
      end
      nodes = root.is_a?(Crystal::Expressions) ? root.expressions : [root]
      violations = [] of Crystal::Call
      nodes.each do |node|
        next if node.is_a?(Crystal::Require) || node.is_a?(Crystal::Nop) || Composites.composite_call?(node)
        if node.is_a?(Crystal::Call) && node.name == "table" && node.obj.to_s == "Punch"
          apply_table(schema, node, file, modules, errors)
        elsif node.is_a?(Crystal::Call) && node.name == "violation" && node.obj.to_s == "Punch"
          violations << node
        else
          errors << error(file, node, "#{file} may only contain `Punch.table \"name\", Module, column: Type, …`, `Punch.composite Name, field: Type, …`, and `Punch.violation \"code\", Type, status: 409` calls")
        end
      end
      # After the tables, which they belong to.
      violations.each { |node| apply_violation(schema, node, file, errors) }
      errors
    end

    STATUSES = {409, 422}
    # As `Punch::Invalid` codes are written.
    CODE_FORMAT = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

    # `Punch.violation "invoice_locked", Billing::Invoices::Locked, status: 409`:
    # the rule a trigger raises as `RAISE(ABORT, 'punch:invoice_locked')`
    # becomes a value of the writes that fire it.
    private def self.apply_violation(schema : Schema, node : Crystal::Call, file : String, errors : Array(Error)) : Nil
      code, type, status, field = violation_arguments(node, file, errors) || return
      table = violation_table(schema, code, type, file, errors) || return
      if table.uniques.any?(&.code.==(code.value))
        errors << error(file, code, "#{code.value} is declared twice")
        return
      end
      if table.uniques.any?(&.type_name.==(type.names.last))
        errors << error(file, type, "#{type} is the type of another violation of #{table.name}")
        return
      end
      unique = Schema::Unique.trigger(code.value, schema.triggers.select(&.codes.includes?(code.value)))
      unique.type_name = type.names.last
      unique.status = status
      unique.field = field
      table.uniques << unique
    end

    # The code, type, status, and field of a `Punch.violation`, checked.
    private def self.violation_arguments(node : Crystal::Call, file : String, errors : Array(Error)) : {Crystal::StringLiteral, Crystal::Path, Int32, String?}?
      code, type = node.args[0]?, node.args[1]?
      named = (node.named_args || [] of Crystal::NamedArgument).to_h { |argument| {argument.name, argument.value} }
      status, field = named["status"]?, named["field"]?
      unless violation_shape?(node, named) && code.is_a?(Crystal::StringLiteral) && type.is_a?(Crystal::Path) && status.is_a?(Crystal::NumberLiteral)
        errors << error(file, node, "Punch.violation takes the code as a string, the type, and `status: 409` or `status: 422`, with `field: \"name\"` for a 422 that belongs to one field")
        return
      end
      unless code.value.matches?(CODE_FORMAT)
        errors << error(file, code, "#{code.value.inspect} is not a code: lowercase words joined by _, such as \"invoice_locked\"")
        return
      end
      value = status.value.to_i
      unless value.in?(STATUSES) && (field.nil? || value == 422)
        errors << error(file, status, field && value != 422 ? "a field goes with status: 422; a 409 answers for the request as a whole" : "Punch.violation answers 409 or 422, not #{status.value}")
        return
      end
      {code, type, value, field.as?(Crystal::StringLiteral).try(&.value)}
    end

    # Two arguments, `status:`, and an optional `field:` string.
    private def self.violation_shape?(node : Crystal::Call, named : Hash(String, Crystal::ASTNode)) : Bool
      field = named["field"]?
      node.args.size == 2 && (named.keys - %w[status field]).empty? && (field.nil? || field.is_a?(Crystal::StringLiteral))
    end

    # The one mapped table whose triggers raise *code*, in whose module
    # *type* must be.
    private def self.violation_table(schema : Schema, code : Crystal::StringLiteral, type : Crystal::Path, file : String, errors : Array(Error)) : Schema::Table?
      raising = schema.triggers.select(&.codes.includes?(code.value))
      if raising.empty?
        errors << error(file, code, "no trigger in the schema raises 'punch:#{code.value}'; raise it with RAISE(ABORT, 'punch:#{code.value}')")
        return
      end
      tables = raising.map(&.table).uniq!
      table = schema.table(tables.first)
      if tables.size > 1 || table.nil?
        errors << error(file, code, "'punch:#{code.value}' is raised by triggers on #{tables.join(" and ")}; give each table's rule its own code")
        return
      end
      mod = table.mod
      expected = "#{mod}::#{type.names.last}"
      unless mod && type.to_s == expected
        errors << error(file, type, mod ? "#{code.value} belongs to #{table.name}, so its type is #{expected}" : "#{table.name} raises 'punch:#{code.value}' but is not mapped; map it with Punch.table in this file")
        return
      end
      table
    end

    private def self.apply_table(schema : Schema, node : Crystal::Call, file : String, modules : Hash(String, String), errors : Array(Error)) : Nil
      table_name, mod = node.args[0]?, node.args[1]?
      unless node.args.size == 2 && table_name.is_a?(Crystal::StringLiteral) && mod.is_a?(Crystal::Path)
        errors << error(file, node, "Punch.table takes the table name as a string and the module for its record, then `column: Type` pairs")
        return
      end
      if (namespace = QueryGen.namespace(file)) && mod.to_s != namespace && !mod.to_s.starts_with?("#{namespace}::")
        parts = ::Path[file].parts
        root = parts[0..parts.rindex!(&.in?("app", "src"))]
        beside = File.join(root + mod.names.map { |name| QueryGen.underscore(name) } + ["columns.cr"])
        errors << error(file, mod, "#{file} maps only tables of #{namespace}; map #{table_name.value} in #{beside}, beside #{mod}")
        return
      end
      table = schema.table(table_name.value)
      unless table
        errors << error(file, table_name, "no table #{table_name.value} in the schema")
        return
      end
      if table.mod
        errors << error(file, table_name, "#{table.name} is mapped twice")
        return
      end
      if other = modules[mod.to_s]?
        errors << error(file, mod, "#{mod} is the module of #{other} already; each table needs its own")
        return
      end
      modules[mod.to_s] = table.name
      table.mod = mod.to_s
      table.mapped_at = error(file, node, "").location
      table.mapped_in = file
      apply_columns(schema, table, node, node.named_args || [] of Crystal::NamedArgument, file, errors)
    end

    private def self.apply_columns(schema : Schema, table : Schema::Table, node : Crystal::Call, arguments : Array(Crystal::NamedArgument), file : String, errors : Array(Error)) : Nil
      # Blind indexes last: they read the encrypted column they hash.
      blind, columns = arguments.partition { |argument| blind?(argument.value) }
      # Groups first: their columns may not be mapped one by one.
      groups, columns = columns.partition(&.value.is_a?(Crystal::NamedTupleLiteral))
      groups.each { |argument| Groups.apply(schema, table, argument, file, errors) }
      columns.each do |argument|
        if (call = argument.value).is_a?(Crystal::Call) && converting?(call)
          apply_column(table, Crystal::NamedArgument.new(argument.name, call.obj.as(Crystal::ASTNode)).at(argument), file, errors)
          apply_conversion(table, argument, call, arguments, file, errors)
        else
          apply_column(table, argument, file, errors)
          Documents.apply(schema, table, argument, file, errors)
        end
      end
      blind.each { |argument| apply_blind_index(table, argument, file, errors) }
      check_secrets(table, arguments, node, file, errors)
    end

    # `Punch::Encrypted(T).from(:email)`, the mapping while a plaintext
    # column is converted.
    private def self.converting?(call : Crystal::Call) : Bool
      call.name == "from" && (receiver = call.obj).is_a?(Crystal::Generic) && encrypted?(receiver)
    end

    # `email_encrypted: Punch::Encrypted(Punch::Email).from(:email)`: the
    # encrypted column reads the plaintext `email` while it has no
    # ciphertext, and writes go to both; with `clear: true`, generated
    # code leaves `email` out, and only the conversion clears it.
    private def self.apply_conversion(table : Schema::Table, argument : Crystal::NamedArgument, call : Crystal::Call, arguments : Array(Crystal::NamedArgument),
                                      file : String, errors : Array(Error)) : Nil
      column = table.column(argument.name) || return
      type = column.type || return
      return unless type.encrypted

      named = call.named_args || [] of Crystal::NamedArgument
      clear = named.find(&.name.==("clear")).try(&.value)
      plain = call.args.first?.as?(Crystal::SymbolLiteral).try { |symbol| table.column(symbol.value) } if call.args.size == 1
      if problem = conversion_problem(table, column, plain, arguments, named, clear)
        errors << error(file, call, problem)
        return
      end
      return unless plain && (stored = plain.type)

      cleared = clear.is_a?(Crystal::BoolLiteral) && clear.value
      inner = type.domain.try(&.lchop("Punch::Encrypted(").rchop(")"))
      column.type = type.copy_with(from: plain.name, filled: !cleared && !stored.nullable)
      plain.type = stored.copy_with(domain: inner, plaintext_of: column.name)
      plain.plaintext_of = column.name
      plain.cleared = cleared
    end

    private def self.conversion_problem(table : Schema::Table, column : Schema::Column, plain : Schema::Column?, arguments : Array(Crystal::NamedArgument),
                                        named : Array(Crystal::NamedArgument), clear : Crystal::ASTNode?) : String?
      name = "#{table.name}.#{column.name}"
      return "#{name}: from takes the plaintext column it replaces, such as from(:email)" unless plain
      return "#{name}: from takes only clear: true or false" unless named.all?(&.name.==("clear")) && (clear.nil? || clear.is_a?(Crystal::BoolLiteral))
      return "#{name}: #{table.name}.#{plain.name} is mapped by from; leave it out of the mapping" if arguments.any?(&.name.==(plain.name))
      return "#{name}: #{table.name}.#{plain.name} is declared #{plain.declared}; from converts a column of the value's stored type, TEXT, INTEGER, or REAL" unless plain.type.try(&.stored).in?("String", "Int64", "Float64")
      return if !clear.is_a?(Crystal::BoolLiteral) || !clear.value || plain.type.try(&.nullable)

      "#{name}: clearing #{table.name}.#{plain.name} writes NULL into it, but it is NOT NULL; make it nullable first, in a migration that rebuilds #{table.name}"
    end

    private def self.check_secrets(table : Schema::Table, arguments : Array(Crystal::NamedArgument), node : Crystal::Call, file : String, errors : Array(Error)) : Nil
      table.columns.each do |column|
        problem = secret_problem(table, column) || next
        errors << error(file, arguments.find(&.name.==(column.name)) || node, problem)
      end
    end

    private def self.apply_column(table : Schema::Table, argument : Crystal::NamedArgument, file : String, errors : Array(Error)) : Nil
      column = table.column(argument.name)
      type = argument.value
      message = column_problem(table, column, argument)
      if message
        errors << error(file, column ? type : argument, message)
      elsif column && (stored = column.type)
        if inner = encrypted(type)
          column.type = stored.copy_with(domain: "Punch::Encrypted(#{inner})", encrypted: "#{table.name}.#{column.name}")
        else
          column.type = stored.copy_with(domain: type.to_s)
        end
      end
    end

    private def self.blind?(type : Crystal::ASTNode) : Bool
      type.is_a?(Crystal::Call) && type.name == "of" && type.obj.to_s.lchop("::") == "Punch::BlindIndex"
    end

    # `email_index: Punch::BlindIndex.of(:email)`: a BLOB column holding
    # the keyed hash of the encrypted column `email`.
    private def self.apply_blind_index(table : Schema::Table, argument : Crystal::NamedArgument, file : String, errors : Array(Error)) : Nil
      call = argument.value.as(Crystal::Call)
      name = "#{table.name}.#{argument.name}"
      column = table.column(argument.name)
      source = call.args.first?.as?(Crystal::SymbolLiteral).try { |symbol| table.column(symbol.value) } if call.args.size == 1 && !call.named_args
      if problem = blind_index_problem(table, argument.name, column, source)
        errors << error(file, column && source ? call : argument, problem)
        return
      end
      return unless column && source && (stored = column.type) && (inner = source.type.try(&.domain))

      column.type = stored.copy_with(domain: inner.lchop("Punch::Encrypted(").rchop(")"), blind: name)
      column.source = source.name
    end

    private def self.blind_index_problem(table : Schema::Table, argument : String, column : Schema::Column?, source : Schema::Column?) : String?
      name = "#{table.name}.#{argument}"
      return "no column #{argument} in #{table.name}" unless column
      unless source && source.type.try(&.encrypted)
        return "#{name}: Punch::BlindIndex.of takes an encrypted column of #{table.name}, such as Punch::BlindIndex.of(:email)"
      end
      return "#{name} is #{column.declared.presence || "declared without a type"}, but a blind index holds hashes; declare it BLOB" unless column.type.try(&.stored) == "Bytes"
      unless name.matches?(/\A[a-z0-9_]+\.[a-z0-9_]+\z/)
        return "#{name}: the key of a blind index is derived from its name, so the table and column names must be lowercase letters, digits, and _"
      end

      table.columns.find(&.source.==(source.name)).try { |other| "#{name}: #{table.name}.#{source.name} has a blind index already, #{other.name}" }
    end

    # What the schema does with an encrypted column or a blind index that
    # it cannot do: an index on ciphertext, which differs on every write, or
    # a `CHECK`, which sees ciphertext or a hash.
    private def self.secret_problem(table : Schema::Table, column : Schema::Column) : String?
      name = "#{table.name}.#{column.name}"
      if column.type.try(&.encrypted)
        index = table.indexes.find { |_, columns| columns.includes?(column.name) }
        if index && table.uniques.none?(&.name.==(index[0]))
          return "#{name} is encrypted, so the index #{index[0]} orders ciphertext, which differs for every write; drop it, and index a blind index instead (Punch::BlindIndex.of)"
        end
      end
      return unless column.type.try(&.secret_column) && table.checked.includes?(column.name)

      "#{name} is #{column.type.try(&.encrypted) ? "encrypted" : "a blind index"}, so a CHECK on it sees #{column.type.try(&.encrypted) ? "ciphertext" : "a hash"}, never the value; check the value in its domain type instead"
    end

    def self.encrypted?(type : Crystal::ASTNode) : Bool
      type.is_a?(Crystal::Generic) && type.name.to_s.lchop("::") == "Punch::Encrypted"
    end

    # The one type inside `Punch::Encrypted(T)`, if *type* is one.
    def self.encrypted(type : Crystal::ASTNode) : Crystal::ASTNode?
      return unless type.is_a?(Crystal::Generic) && encrypted?(type)

      type.type_vars.first? if type.type_vars.size == 1
    end

    # Why *column* cannot be encrypted as *inner*, if it cannot.
    def self.encryption_problem(table : Schema::Table, column : Schema::Column, inner : Crystal::ASTNode?, stored : Type?) : String?
      name = "#{table.name}.#{column.name}"
      return "#{name}: Punch::Encrypted takes one type, such as Punch::Encrypted(Punch::Email)" unless inner.is_a?(Crystal::Path)
      return "#{name} is declared without a type; declare it BLOB to encrypt it" unless stored
      return "#{name} is #{column.declared}, but an encrypted column holds ciphertext; declare it BLOB" unless stored.stored == "Bytes"
      return "#{name}: the key of an encrypted column is derived from its name, so the table and column names must be lowercase letters, digits, and _" unless "#{table.name}.#{column.name}".matches?(/\A[a-z0-9_]+\.[a-z0-9_]+\z/)

      if unique = table.uniques.find(&.columns.includes?(column.name))
        "#{name} is encrypted, so the unique key on #{unique.constraint(table.name)} compares ciphertext, which differs for every write and never finds an equal value; drop it"
      end
    end

    private def self.column_problem(table : Schema::Table, column : Schema::Column?, argument : Crystal::NamedArgument) : String?
      return "no column #{argument.name} in #{table.name}" unless column

      type = argument.value
      stored = column.type
      return encryption_problem(table, column, encrypted(type), stored) if encrypted?(type)
      return "#{table.name}.#{column.name}: the type must be a constant, such as Punch::Email" unless type.is_a?(Crystal::Path)
      return "#{table.name}.#{column.name} is declared #{column.declared.empty? ? "without a type" : column.declared}; give it INTEGER, REAL, TEXT, or BLOB to map it" unless stored

      name = type.to_s
      if group = column.group
        return "#{table.name}.#{column.name} belongs to the group #{group.field}; leave it out of the mapping"
      end
      if (needed = BUILTIN_DOMAINS[name]?) && needed != stored.stored
        return "#{table.name}.#{column.name} is #{column.declared}, but #{name} is stored as #{needed == "String" ? "TEXT" : "INTEGER"}"
      end

      "#{table.name}.#{column.name}: #{name} is a stored type; map columns to domain types only" if STORED_TYPES.includes?(name)
    end

    def self.error(file : String, node : Crystal::ASTNode, message : String) : Error
      location = node.location
      Error.new(Location.new(file, location.try(&.line_number) || 1, location.try(&.column_number)), message)
    end
  end
end
