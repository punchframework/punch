module Punch::QueryGen
  # `address: {type: Billing::Address?, columns: "address_"}` in
  # `Punch.table`: a composite stored in prefixed columns, one per field,
  # nested composites joining their prefixes (`address_geo_lat`). The
  # columns stay plain columns, so foreign keys, indexes, and CHECKs work
  # on them; the record holds the composite (docs/composites.md).
  module Groups
    PREFIX = /\A[a-z][a-z0-9_]*_\z/

    def self.apply(schema : Schema, table : Schema::Table, argument : Crystal::NamedArgument, file : String, errors : Array(Error)) : Nil
      tuple = argument.value.as(Crystal::NamedTupleLiteral)
      what = "#{table.name}.#{argument.name}"
      type, prefix, nilable = declared(tuple) || return errors << Mapping.error(file, tuple, "#{what}: a group of columns is {type: Composite, columns: \"prefix_\"}")
      composite = schema.composites[type.to_s.lchop("::")]? if type.is_a?(Crystal::Path)
      if problem = group_problem(table, argument.name, composite, prefix, schema)
        errors << Mapping.error(file, composite ? tuple : type, "#{what}: #{problem}")
        return
      end
      return unless composite

      group = Schema::Group.new(argument.name, composite, prefix, nilable)
      before = errors.size
      flatten(schema, table, group, composite, prefix, [] of String, nilable, file, argument, errors)
      # A column of the group mapped by itself is reported by its own mapping.
      return if errors.size > before

      check_absence(schema, table, group, composite, [] of String, nilable, file, argument, errors)
      table.groups << group
      Composites.reachable(composite.name, schema.composites).each(&.grouped = true)
    end

    # The type, prefix, and nilability of `{type: T?, columns: "prefix_"}`.
    private def self.declared(tuple : Crystal::NamedTupleLiteral) : {Crystal::ASTNode, String, Bool}?
      type = tuple.entries.find(&.key.==("type")).try(&.value)
      prefix = tuple.entries.find(&.key.==("columns")).try(&.value).as?(Crystal::StringLiteral).try(&.value)
      return unless type && prefix && tuple.entries.size == 2

      if type.is_a?(Crystal::Generic) && type.name.to_s.lchop("::") == "Union" && type.type_vars.size == 2 && type.type_vars.last.to_s.lchop("::") == "Nil"
        return {type.type_vars.first, prefix, true}
      end
      {type, prefix, false}
    end

    private def self.group_problem(table : Schema::Table, field : String, composite : Composite?, prefix : String, schema : Schema) : String?
      return "the type is a composite declared with Punch.composite, optionally nilable (Billing::Address?)" unless composite
      return "#{table.name}.#{field} is a column; give the group's field another name" if table.column(field)
      return "the prefix #{prefix.inspect} is lowercase letters, digits, and _, ending in _ (\"address_\")" unless prefix.matches?(PREFIX)
      return "#{table.name} has a group named #{field} already" if table.groups.any?(&.field.==(field))

      Composites.reachable(composite.name, schema.composites).each do |held|
        return "#{held.name} is polymorphic; it can only be stored as a JSON document" if held.polymorphic?
        if list = held.fields.find { |candidate| candidate.type.kind.array? || candidate.type.kind.map? }
          return "#{held.name}.#{list.name} is a list; a group of columns has one value per column, so store it as a JSON document or a child table"
        end
      end
      nil
    end

    # Maps each field to its column, nested composites by their joined
    # prefix. *optional*: somewhere above, the group or a composite field
    # is nilable, so its columns hold NULL when it is absent.
    private def self.flatten(schema : Schema, table : Schema::Table, group : Schema::Group, composite : Composite, prefix : String, path : Array(String),
                             optional : Bool, file : String, argument : Crystal::NamedArgument, errors : Array(Error)) : Nil
      composite.fields.each do |field|
        if field.type.kind.composite?
          nested = schema.composites[field.type.name]? || next
          flatten(schema, table, group, nested, "#{prefix}#{field.name}_", path + [field.name], optional || field.type.nilable?, file, argument, errors)
          next
        end
        name = "#{prefix}#{field.name}"
        column = table.column(name)
        unless column && (stored = column.type)
          errors << Mapping.error(file, argument, "#{table.name}.#{argument.name}: #{composite.name}.#{field.name} goes in the column #{name}, which #{table.name} #{column ? "declares without a type" : "does not have"}")
          next
        end
        if other = column.group
          errors << Mapping.error(file, argument, "#{table.name}.#{name} belongs to the group #{other.field} already")
          next
        end
        if problem = column_problem(table, column, stored, field, optional)
          errors << Mapping.error(file, argument, "#{table.name}.#{argument.name}: #{problem}")
          next
        end
        column.type = typed(table, column, stored, field)
        column.group = group
        column.member = path + [field.name]
        group.columns << column
      end
    end

    # The column's type with the field's domain type.
    private def self.typed(table : Schema::Table, column : Schema::Column, stored : Type, field : CompositeField) : Type
      name = field.type.name
      if field.type.kind.secret?
        stored.copy_with(domain: "Punch::Encrypted(#{name})", encrypted: "#{table.name}.#{column.name}")
      elsif STORED_TYPES.includes?(name)
        stored
      else
        stored.copy_with(domain: name)
      end
    end

    # What keeps *column* from holding *field*: its stored type, whether it
    # can be NULL, and its default.
    private def self.column_problem(table : Schema::Table, column : Schema::Column, stored : Type, field : CompositeField, optional : Bool) : String?
      type_problem(table, column, stored, field) || null_problem(table, column, stored, field, optional) ||
        # Where the group or a composite on the way may be absent, the column
        # is NULL then, so it has no default to compare.
        (default_problem("#{table.name}.#{column.name}", column, field) unless optional)
    end

    private def self.type_problem(table : Schema::Table, column : Schema::Column, stored : Type, field : CompositeField) : String?
      type = field.type
      return Mapping.encryption_problem(table, column, Crystal::Path.new(type.name.split("::")), stored) if type.kind.secret?

      needed = BUILTIN_DOMAINS[type.name]? || (STORED_TYPES.includes?(type.name) ? type.name : nil)
      return unless needed && needed != stored.stored

      "#{table.name}.#{column.name} is #{column.declared}, but #{type.name} is stored as #{{"String" => "TEXT", "Int64" => "INTEGER"}[needed]? || "REAL"}"
    end

    private def self.null_problem(table : Schema::Table, column : Schema::Column, stored : Type, field : CompositeField, optional : Bool) : String?
      name = "#{table.name}.#{column.name}"
      nilable = field.type.nilable?
      return "#{name} holds the required field #{field.name}, so it is NOT NULL" if !optional && !nilable && stored.nullable
      return if stored.nullable || !(optional || nilable)

      "#{name} holds #{nilable ? "the nilable field #{field.name}" : "a field of a nilable composite"}, so it can be NULL; drop its NOT NULL"
    end

    # A field's default is the column's `DEFAULT`, the same literal.
    private def self.default_problem(name : String, column : Schema::Column, field : CompositeField) : String?
      value = field.value
      return if value.nil? && column.default.nil?
      return if value.nil? # a column default the composite does not know is harmless: writes always bind the field
      expected = sql_literal(value)
      actual = column.default.try(&.strip.lchop('(').rchop(')').strip)
      return if actual == expected

      "#{name} needs DEFAULT #{expected}, the default of the field #{field.name} (#{field.default}); it has #{actual ? "DEFAULT #{actual}" : "none"}"
    end

    # A default as SQL writes it: `'EUR'`, `14`, `1` for true.
    def self.sql_literal(value : JSON::Any) : String
      case raw = value.raw
      when String then "'#{raw.gsub("'", "''")}'"
      when Bool   then raw ? "1" : "0"
      else             raw.to_s
      end
    end

    # A nilable group, or a nilable composite inside a group, is absent
    # when every column it has is NULL; a CHECK must keep its required
    # columns all NULL or all set, or a row could hold part of one.
    private def self.check_absence(schema : Schema, table : Schema::Table, group : Schema::Group, composite : Composite, path : Array(String),
                                   nilable : Bool, file : String, argument : Crystal::NamedArgument, errors : Array(Error)) : Nil
      if nilable
        required = required_columns(schema, group, path)
        if required.empty?
          errors << Mapping.error(file, argument, "#{table.name}.#{argument.name}: #{composite.name} is nilable here, but has no required field to tell an absent one from one whose fields are all nil")
        elsif (required.size > 1 || group_columns(group, path).size > required.size) &&
              group_columns(group, path).any? { |column| !table.checked.includes?(column.name) }
          errors << Mapping.error(file, argument, "#{table.name}.#{argument.name}: a row could hold part of #{composite.name}; add a CHECK in a migration: ALTER TABLE #{table.name} ADD #{absence_check(schema, group, path)};")
        end
      end
      composite.fields.each do |field|
        next unless field.type.kind.composite?
        nested = schema.composites[field.type.name]? || next
        check_absence(schema, table, group, nested, path + [field.name], field.type.nilable?, file, argument, errors)
      end
    end

    # The group's columns under *path*.
    def self.group_columns(group : Schema::Group, path : Array(String)) : Array(Schema::Column)
      group.columns.select { |column| column.member[0, path.size] == path }
    end

    # The columns under *path* whose fields are required relative to it:
    # not nilable themselves, nor inside a nilable composite below *path*.
    def self.required_columns(schema : Schema, group : Schema::Group, path : Array(String)) : Array(Schema::Column)
      group_columns(group, path).select do |column|
        composite = group.composite
        required = true
        column.member.each_with_index do |name, index|
          field = composite.try(&.field(name))
          required = false if index >= path.size && field.try(&.type.nilable?)
          composite = field.try { |found| schema.composites[found.type.name]? if found.type.kind.composite? }
        end
        required
      end
    end

    # The constraint that keeps the composite under *path* whole: its
    # required columns all NULL or all set, and its optional ones NULL
    # when it is absent.
    def self.absence_check(schema : Schema, group : Schema::Group, path : Array(String)) : String
      required = required_columns(schema, group, path)
      optional = group_columns(group, path) - required
      parts = [] of String
      parts << "(#{required.join(" + ") { |column| "(#{column.name} IS NULL)" }}) IN (0, #{required.size})" if required.size > 1
      parts << "(#{required.first.name} IS NOT NULL OR (#{optional.join(" AND ") { |column| "#{column.name} IS NULL" }}))" unless optional.empty?
      "CHECK (#{parts.join(" AND ")})"
    end
  end

  # `billed_to: Billing::Invoices::BilledTo` in `Punch.table`: a composite
  # stored as a JSON document in one `TEXT` column, which a CHECK keeps
  # JSON, or encrypted as a whole in a `BLOB` (`Punch::Encrypted(T)`).
  module Documents
    def self.apply(schema : Schema, table : Schema::Table, argument : Crystal::NamedArgument, file : String, errors : Array(Error)) : Nil
      column = table.column(argument.name) || return
      type = column.type || return
      inner = Mapping.encrypted(argument.value) || argument.value
      composite = schema.composites[inner.to_s.lchop("::")]? if inner.is_a?(Crystal::Path)
      return unless composite

      encrypted = !type.encrypted.nil?
      if problem = document_problem(schema, table, column, type, composite, encrypted)
        errors << Mapping.error(file, argument.value, problem)
        return
      end
      Composites.reachable(composite.name, schema.composites).each(&.document = true)
    end

    private def self.document_problem(schema : Schema, table : Schema::Table, column : Schema::Column, type : Type, composite : Composite, encrypted : Bool) : String?
      name = "#{table.name}.#{column.name}"
      return "#{name} is #{column.declared}, but a document is JSON text; declare it TEXT" unless encrypted || type.stored == "String"
      return "#{name} is part of the primary key; a document cannot be a key" if column.pk.positive?

      unless encrypted
        if secret = Composites.reachable(composite.name, schema.composites).find { |held| held.fields.any?(&.type.secret?) }
          field = secret.fields.find!(&.type.secret?)
          return "#{name}: #{secret.name}.#{field.name} is encrypted, which a plain document cannot keep; encrypt the whole document, Punch::Encrypted(#{composite.name})"
        end
        unless json_checked?(table, column)
          return "#{name} holds a JSON document, so a CHECK keeps it one; declare the column with: #{json_check(column)}"
        end
      end
      nil
    end

    # Whether a CHECK of the table says the column holds a JSON object.
    private def self.json_checked?(table : Schema::Table, column : Schema::Column) : Bool
      name = column.name.downcase
      table.checks.any? do |check|
        text = check.downcase.gsub(/\s+/, "")
        text.includes?("json_valid(#{name})") && text.includes?("json_type(#{name})='object'")
      end
    end

    def self.json_check(column : Schema::Column) : String
      condition = "json_valid(#{column.name}) AND json_type(#{column.name}) = 'object'"
      nullable = column.type.try(&.nullable)
      "CHECK (#{nullable ? "#{column.name} IS NULL OR (#{condition})" : condition})"
    end
  end
end
