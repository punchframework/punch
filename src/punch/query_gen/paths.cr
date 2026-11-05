module Punch::QueryGen
  # Typed paths into JSON documents (docs/composites.md, "Paths in
  # queries"): `billed_to ->> '$.address.city'` and `json_extract(doc,
  # '$.lines[0].amount')` over a column that holds a composite are typed
  # from the composite, and a path to a field it does not declare is
  # refused. So is a generated column over such a path, which is how a
  # path gets an index. Paths only read: a document is written whole.
  module Paths
    record Segment, key : String?, index : Int32?

    # The type of *literal*, a path as SQL writes it (`'$.a.b'`, or `'a'`
    # after `->>`), into a value of *base*: a `Type`, a message for a path
    # the composite refuses, or `nil` when *base* is not a document.
    def self.resolve(schema : Schema, base : Type, literal : SQL::Token, arrow : Bool) : Type | String?
      domain = base.domain || return
      name = domain.lchop("Punch::Encrypted(").rchop(")")
      composite = schema.composites[name]? || return
      return "#{base.encrypted} is an encrypted document, so a path into it reads ciphertext" if base.encrypted

      segments = parse(literal, arrow) || return "#{literal.text} is not a path this generator reads: $ followed by .field, .\"key\", and [n]"
      walk(schema, composite, segments, base.nullable, literal.text)
    end

    # The segments of a path literal; `nil` for one it does not read.
    def self.parse(literal : SQL::Token, arrow : Bool) : Array(Segment)?
      if literal.kind.number?
        index = literal.text.to_i? if arrow
        return index ? [Segment.new(nil, index)] : nil
      end
      return unless literal.kind.string?

      text = literal.text[1...-1].gsub("''", "'")
      return unless text.starts_with?('$') || arrow

      text = "$.#{text}" unless text.starts_with?('$')
      segments = [] of Segment
      i = 1
      while i < text.size
        segment, i = segment(text, i) || return
        segments << segment
      end
      segments
    end

    # The segment at *i* of a path, and where the next one starts.
    private def self.segment(text : String, i : Int32) : {Segment, Int32}?
      case text[i]
      when '.'
        return quoted_key(text, i + 1) if text[i + 1]? == '"'
        stop = (i + 1...text.size).find { |j| text[j].in?('.', '[') } || text.size
        {Segment.new(text[(i + 1)...stop], nil), stop} if stop > i + 1
      when '['
        close = text.index(']', i) || return
        index = text[(i + 1)...close].to_i? || return
        {Segment.new(nil, index), close + 1}
      end
    end

    private def self.quoted_key(text : String, open : Int32) : {Segment, Int32}?
      close = text.index('"', open + 1) || return
      {Segment.new(text[(open + 1)...close], nil), close + 1}
    end

    private def self.walk(schema : Schema, composite : Composite, segments : Array(Segment), nullable : Bool, text : String) : Type | String
      return Type.new("String", composite.name, nullable) if segments.empty?

      current = FieldType.new(:composite, composite.name)
      segments.each do |segment|
        case current.kind
        in .composite?
          held = schema.composites[current.name]? || return "no composite #{current.name}"
          key = segment.key || return "#{text}: #{held.name} is an object; [#{segment.index}] reads an array"
          found = field(schema, held, key) || return "#{text}: #{held.name} has no field #{key}"
          current, optional = found
          nullable ||= optional
        in .array?
          return "#{text}: an array is read by [n]" unless segment.index
          current = current.element || return "no element"
          nullable = true
        in .map?
          return "#{text}: a map is read by .key" unless segment.key
          current = current.element || return "no element"
          nullable = true
        in .scalar?, .secret?
          return "#{text}: #{current.name} is a value, so the path ends before #{segment.key || "[#{segment.index}]"}"
        end
      end
      leaf(schema, current, nullable, text)
    end

    # The field *key* of *composite*, and whether it may be missing: a
    # polymorphic composite has its key, and each member's fields, which
    # the other members lack.
    private def self.field(schema : Schema, composite : Composite, key : String) : {FieldType, Bool}?
      if discriminator = composite.discriminator
        return {FieldType.new(:scalar, "String"), false} if key == discriminator
        fields = composite.members.compact_map { |_, name| schema.composites[name]?.try(&.field(key)) }
        return if fields.empty?
        return {fields.first.type, true} if fields.all?(&.type.crystal.==(fields.first.type.crystal))

        return
      end
      if (family = composite.family) && key == family.discriminator
        return {FieldType.new(:scalar, "String"), false}
      end
      field = composite.field(key) || return
      # A field with a default may be missing from a document written before it.
      {field.type, field.type.nilable? || !field.default.nil?}
    end

    # The SQL value at the end of a path: what `->>` returns for the JSON
    # value the composite writes there.
    private def self.leaf(schema : Schema, type : FieldType, nullable : Bool, text : String) : Type | String
      nullable ||= type.nilable?
      case type.kind
      in .composite?
        Type.new("String", type.name, nullable)
      in .array?, .map?
        Type.new("String", nil, nullable) # JSON text; read it whole, as its composite
      in .secret?
        "#{text}: the field is encrypted"
      in .scalar?
        case name = type.name
        when "String", "Int64", "Float64" then Type.new(name, nil, nullable)
        when "Bool"                       then Type.new("Int64", "Bool", nullable)
        when "Time"                       then Type.new("String", "Time", nullable)
        else
          stored = schema.primitives.try(&.stored(name))
          stored ? Type.new(stored, name, nullable) : "#{text}: the generator cannot see how #{name} is stored (it looks for `include Punch::Primitive(T)` and `< Punch::TypedID` under app/ and src/); annotate the column"
        end
      end
    end

    # Generated columns over a path into a document of their table
    # (`AS (doc ->> '$.city')`) get the path's type, unless `columns.cr`
    # maps them.
    def self.type_generated(schema : Schema, path : String, errors : Array(Error)) : Nil
      text = File.read(path)
      schema.tables.each_value do |table|
        table.columns.each do |column|
          expression = column.expression || next
          stored = column.type || next
          next if stored.domain
          base, literal, arrow = path_expression(table, expression) || next
          resolved = resolve(schema, base, literal, arrow)
          location = Location.new(path, line(text, column.name))
          case resolved
          in Nil
            next
          in String
            errors << Error.new(location, "#{table.name}.#{column.name}: #{resolved}")
          in Type
            if resolved.stored != stored.stored
              errors << Error.new(location, "#{table.name}.#{column.name} is #{column.declared}, but the path gives #{resolved.stored == "String" ? "TEXT" : resolved.stored == "Int64" ? "INTEGER" : "REAL"}")
            else
              column.type = stored.copy_with(domain: resolved.domain)
            end
          end
        end
      end
    end

    # `doc ->> 'path'` or `json_extract(doc, 'path')` over a column of
    # *table*: its type, the path, and whether it is the arrow form.
    private def self.path_expression(table : Schema::Table, expression : String) : {Type, SQL::Token, Bool}?
      tokens = SQL.tokenize(expression)
      if tokens.size == 3 && tokens[0].kind.ident? && tokens[1].punct?("->>")
        type = table.column(tokens[0].text).try(&.type) || return
        return {type, tokens[2], true}
      end
      return unless tokens.size == 6 && tokens[0].keyword?("json_extract") && tokens[1].punct?("(") && tokens[3].punct?(",") && tokens[5].punct?(")")

      type = table.column(tokens[2].text).try(&.type) || return
      {type, tokens[4], false}
    end

    private def self.line(text : String, name : String) : Int32
      offset = text.index(/\b#{Regex.escape(name)}\b[^,\n]*\bAS\s*\(/i) || return 1
      text[0, offset].count('\n') + 1
    end
  end
end
