module Punch::QueryGen
  # The declared clauses of a query, checked: what its `Filter` and `Order`
  # hold, and the statement in pieces for the method that joins them.
  class Filtered
    # A field of `Filter`: the clause's parameter, or `nil` for a clause
    # without one, which a `Bool` turns on. A field named by an enum
    # (*enum_type*) has one clause per member, *members*, and *clause* is
    # the first of them.
    record Field, clause : Clause, param : Invalid::Param?, enum_type : String? = nil, members : Array(Clause) = [] of Clause do
      def key : String
        clause.key
      end

      # The field's Crystal type, nilable unless a toggle.
      def type : String
        enum_type.try { |name| "#{name}?" } || param.try(&.type.nilable.crystal) || "Bool"
      end
    end

    # A run of the statement: fixed text, one clause, or where a `:page`
    # query's condition after a cursor goes (*after*, with no text of its
    # own). *sql* has `?` for each parameter, which *params* names in order.
    record Piece, clause : Clause?, sql : String, params : Array(String), after : Bool = false

    getter fields : Array(Field)
    getter orders : Array(Clause)
    getter pieces : Array(Piece)
    # Each statement the generator prepared, with what it switched on, for
    # `punch db:explain` and the report.
    getter variants : Array({String, String})
    # A `:page` query's keyset.
    getter keyset : Keyset?

    def initialize(@fields, @orders, @pieces, @variants, @keyset = nil)
    end
  end

  # Checks a query's declared clauses. Each `when` clause must narrow the
  # query and nothing else: it starts with `AND`, and neither it nor the
  # condition it extends has an `OR` outside parentheses, which would let
  # rows through that the rest of the condition excludes, such as another
  # owner's. Every combination the generator cannot rule out is prepared:
  # the base query, each clause alone, all of them with each order.
  class Clauses
    RESERVED = {"filter", "order", "direction", "args", "io", "value"}
    # Names the method of a `:page` query uses as well.
    RESERVED_PAGE = {"after", "limit", "cursor", "rows", "key"}

    # Whether a check found a mistake.
    getter? failed = false

    # Parameters compared with a blind index, which bind several hashes.
    @lookups = Set(String).new

    def initialize(@query : Query, @sql : String, @tokens : Array(SQL::Token), @errors : Array(Error))
    end

    # What can be checked on the statement's text, before SQLite prepares
    # it: each clause's shape. True for a query without clauses.
    def check_structure : Bool
      ok = @query.orders.map { |clause| check_order(clause) }.all?
      lines = @query.orders.map(&.line)
      unless lines.empty? || lines.last - lines.first == lines.size - 1
        ok = fail(@query.orders.first.location, "the order clauses go on consecutive lines, where the ORDER BY belongs") || false
      end
      @query.whens.map { |clause| check_when(clause) }.all? && ok
    end

    # The rest, once the full statement prepared: reads only, every variant
    # prepares, and the fields. `nil` for a query with neither clauses nor
    # a *keyset*, and when `failed?`.
    def check(connection : Database::Driver::Connection, shape : Database::Driver::Shape, params : Array(Invalid::Param), keyset : Keyset? = nil) : Filtered?
      return if @query.clauses.empty? && keyset.nil?
      return fail(@query.clauses.first.location, "declared clauses narrow reads; a write states its conditions as parameters") unless shape.read_only
      return unless check_variants(connection) && (keyset.nil? || check_pages(connection, keyset))

      fields = fields(params, keyset) || return
      @lookups = params.select { |param| param.type.lookup && !param.type.array }.map(&.name).to_set
      prepared = variants.map { |label, switched| {label, @query.assemble(switched)} }
      prepared.insert(1, {"with every when#{@query.orders.first?.try { |order| " and order #{order.key}" }}", @sql}) unless @query.clauses.empty?
      keyset.try do |found|
        found.keys.each { |key| prepared << {page_label(key), found.assemble(@query, page_clauses(key), key)} }
        prepared << {"by key, with every when", found.assemble_by_key(@query, @query.whens)}
      end
      Filtered.new(fields, @query.orders, pieces(keyset), prepared, keyset)
    end

    private def fail(location : Location, message : String) : Nil
      @failed = true
      @errors << Error.new(location, "query #{@query.name}: #{message}")
      nil
    end

    # Where *clause*'s SQL starts in the assembled statement.
    private def start(clause : Clause) : Int32
      @sql.lines(chomp: false).first(clause.line).sum(&.size) + clause.prefix
    end

    private def clause_tokens(clause : Clause) : Range(Int32, Int32)
      from = start(clause)
      to = from + clause.sql.size
      first = @tokens.index { |token| token.offset >= from } || @tokens.size
      last = @tokens.rindex { |token| token.offset < to } || -1
      first..last
    end

    private def location(token : SQL::Token) : Location
      @query.location_at(token.offset)
    end

    private def check_order(clause : Clause) : Bool
      tokens = SQL.tokenize(clause.sql)
      if !(tokens[0]?.try(&.keyword?("ORDER")) && tokens[1]?.try(&.keyword?("BY")))
        fail(clause.location, "order #{clause.key}: an order clause is `ORDER BY …`")
      elsif param = tokens.find(&.kind.param?)
        fail(clause.location, "order #{clause.key}: an order takes no parameters (:#{param.text}); the sort is chosen by the enum, never by a value")
      elsif SQL.order_terms(clause.sql).first?.try(&.[1])
        fail(clause.location, "order #{clause.key}: write an order ascending in its first term, and `direction: :desc` reads it backwards, so that asc and desc say what they mean")
      else
        return true
      end
      false
    end

    private def check_when(clause : Clause) : Bool
      range = clause_tokens(clause)
      first = @tokens[range.begin]?
      unless first && range.size > 0 && first.keyword?("AND")
        fail(clause.location, "when #{clause.label}: a clause narrows the condition before it, so it starts with AND")
        return false
      end
      if top = top_level_or(range.begin + 1, range.end)
        fail(location(@tokens[top]), "when #{clause.label}: an OR outside parentheses would let in rows the rest of the condition excludes; write AND (… OR …)")
        return false
      end
      opening = condition_start(range.begin) || begin
        fail(clause.location, "when #{clause.label}: a clause extends a WHERE, HAVING, or ON condition; write one before it, `WHERE true` if nothing else")
        return false
      end
      closing = SQL.condition_end(@tokens, range.end)
      if top = top_level_or(opening + 1, closing)
        fail(location(@tokens[top]), "when #{clause.label}: the condition it extends has an OR outside parentheses, so the clause would not narrow all of it; put that OR in parentheses")
        return false
      end
      true
    end

    # The index of the WHERE, HAVING, or ON whose condition holds the token
    # at *index*, at the same depth.
    private def condition_start(index : Int32) : Int32?
      depth = 0
      (index - 1).downto(0) do |i|
        token = @tokens[i]
        if SQL.closes?(token)
          depth += 1
        elsif SQL.opens?(token)
          return if depth == 0

          depth -= 1
        elsif depth == 0 && token.keyword?("WHERE", "HAVING", "ON")
          return i
        end
      end
      nil
    end

    # The first OR outside parentheses in tokens *from* to *to*.
    private def top_level_or(from : Int32, to : Int32) : Int32?
      depth = 0
      (from..to).each do |i|
        token = @tokens[i]
        if SQL.opens?(token)
          depth += 1
        elsif SQL.closes?(token)
          depth -= 1
        elsif depth == 0 && token.keyword?("OR")
          return i
        end
      end
      nil
    end

    # What the generator prepares besides the full statement, which the
    # analyzer types: the query as written, each `when` alone, and every
    # `when` with each further order.
    private def variants : Array({String, Array(Clause)})
      whens = @query.whens
      list = [{"as written", [] of Clause}]
      whens.each { |clause| list << {"with only when #{clause.label}", [clause]} } if whens.size > 1
      @query.orders.skip(1).each { |order| list << {"with every when and order #{order.key}", whens + [order]} }
      @query.orders.each { |order| list << {"with every when and order #{order.key} desc", whens + [order.reversed]} }
      list
    end

    # Every clause, *key*'s order, and the condition after a cursor: what a
    # page after the first runs.
    private def page_clauses(key : Keyset::Key) : Array(Clause)
      @query.whens + (key.order.try { |order| [order] } || [] of Clause)
    end

    private def page_label(key : Keyset::Key) : String
      "with every when#{key.order.try { |order| ", order #{order.key}#{order.reversed? ? " desc" : ""}," }} after a cursor"
    end

    private def check_pages(connection : Database::Driver::Connection, keyset : Keyset) : Bool
      checked = keyset.keys.map do |key|
        connection.shape(keyset.assemble(@query, page_clauses(key), key))
        true
      rescue ex : Database::Error
        fail(key.order.try(&.location) || @query.location, "#{page_label(key)}: #{ex.detail}") || false
      end.all?
      return false unless checked

      connection.shape(keyset.assemble_by_key(@query, @query.whens))
      true
    rescue ex : Database::Error
      fail(@query.location, "by key: #{ex.detail}") || false
    end

    # The orders read backwards are prepared once the rest passed, so a
    # mistake in an order is reported once.
    private def check_variants(connection : Database::Driver::Connection) : Bool
      backwards, forwards = variants.partition { |_, switched| switched.any?(&.reversed?) }
      prepare(connection, forwards) && prepare(connection, backwards)
    end

    private def prepare(connection : Database::Driver::Connection, list : Array({String, Array(Clause)})) : Bool
      list.map do |label, switched|
        sql = @query.assemble(switched)
        connection.shape(sql)
        true
      rescue ex : Database::Error
        location = ex.offset.try { |offset| @query.location_at(sql.byte_slice(0, offset).size) } if sql
        fail(location || (switched.last? || @query).location, "#{label}: #{ex.detail}") || false
      end.all?
    end

    # The fields of `Filter`, one per `when` clause.
    private def fields(params : Array(Invalid::Param), keyset : Keyset?) : Array(Filtered::Field)?
      reserved = params.select { |param| RESERVED.includes?(param.name) || (keyset && RESERVED_PAGE.includes?(param.name)) }
      reserved.each { |param| fail(@query.location, "parameter :#{param.name}: the method of a query with #{keyset ? "pages" : "clauses"} uses this name; rename it") }
      @query.whens.each do |clause|
        next unless keyset && RESERVED_PAGE.includes?(clause.key) && reserved.none?(&.name.==(clause.key))
        fail(clause.location, "when #{clause.key}: the method of a page query uses this name; rename the clause")
      end
      owners = parameter_owners
      by_name = params.to_h { |param| {param.name, param} }
      fields = @query.whens.reject(&.member).map { |clause| field(clause, owners, by_name) }
      enums = @query.whens.select(&.member).group_by(&.key).map { |key, members| enum_field(key, members, owners) }
      fields += enums
      fields.sort_by! { |field| field.try(&.clause.line) || -1 }
      fields.all? && reserved.empty? && !failed? ? fields.compact : nil
    end

    # Each parameter's name to the keys of the clauses that use it, `""`
    # for the rest of the statement.
    private def parameter_owners : Hash(String, Set(String))
      owners = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
      clauses = @query.whens.map { |clause| {clause, clause_tokens(clause)} }
      @tokens.each_with_index do |token, index|
        next unless token.kind.param?
        owner = clauses.find { |_, range| range.includes?(index) }
        owners[token.text] << (owner ? owner[0].key : "")
      end
      owners
    end

    private def field(clause : Clause, owners : Hash(String, Set(String)), by_name : Hash(String, Invalid::Param)) : Filtered::Field?
      names = owners.select { |_, keys| keys.includes?(clause.key) }.keys
      name = names.first?
      param = name.try { |found| by_name[found]? }
      problem = if names.size > 1
                  "one parameter per clause (it has :#{names.join(", :")}); split it into clauses"
                elsif name && name != clause.key
                  "name the clause after its parameter, `-- when #{name}:`, which becomes the filter field"
                elsif name && owners[name].size > 1
                  ":#{name} is used outside this clause too; a clause's parameter is its filter field and cannot be required elsewhere"
                elsif param && param.type.domain.nil? && param.type.stored == "Bytes"
                  ":#{name} is Bytes, which a filter cannot read from a query string"
                end
      return Filtered::Field.new(clause, param) unless problem

      fail(clause.location, "when #{clause.key}: #{problem}")
    end

    # A field whose clauses stand for the members of an enum: they take no
    # parameter, since the member chooses the clause. Whether every member
    # has one is the compiler's check, on the generated `case … in`.
    private def enum_field(key : String, members : Array(Clause), owners : Hash(String, Set(String))) : Filtered::Field?
      if name = owners.find { |_, keys| keys.includes?(key) }.try(&.[0])
        return fail(members.first.location, "when #{key}: a member's clause takes no parameter (it has :#{name}); the member chooses the clause")
      end

      # Without its enum the query file already reported the clauses.
      type = @query.enums[key]?.try(&.[0]) || return
      Filtered::Field.new(members.first, nil, type, members)
    end

    # The statement in runs of fixed text and clauses, each with `?` for
    # its parameters, and the place of a keyset's condition.
    private def pieces(keyset : Keyset?) : Array(Filtered::Piece)
      by_line = @query.clauses.to_h { |clause| {clause.line, clause} }
      pieces = [] of Filtered::Piece
      fixed = [] of String
      flush = -> do
        pieces << piece(nil, fixed.join('\n')) unless fixed.join.blank?
        fixed.clear
      end
      after = -> do
        flush.call
        pieces << Filtered::Piece.new(nil, "", [] of String, after: true)
      end
      @query.sql.lines.each_with_index do |line, index|
        split = keyset.try(&.column) if keyset.try(&.line) == index
        if clause = by_line[index]?
          flush.call
          pieces << piece(clause, clause.sql)
        elsif split
          fixed << line[0...split].rstrip
          after.call
          fixed << line[split..].lstrip
        else
          fixed << line
        end
        after.call if keyset && keyset.line == index && keyset.column.nil?
      end
      flush.call
      pieces
    end

    private def piece(clause : Clause?, text : String) : Filtered::Piece
      names = [] of String
      sql = Analyzer.positional(text, SQL.tokenize(text), @lookups) do |name|
        names << name
        "?"
      end
      Filtered::Piece.new(clause, sql, names)
    end
  end
end
