module Punch::QueryGen
  # Where a type came from, for the report.
  enum Source
    Metadata   # an origin column reported by SQLite, typed by the schema
    Inferred   # the generator's rules for expressions and parameter contexts
    Annotation # declared in the query header
  end

  record ResultColumn, name : String, type : Type, source : Source, table : String?, origin : String?
  record Invalid::Param, name : String, type : Type, source : Source

  # A query checked against the schema, with every type known.
  class Analysis
    getter query : Query
    getter columns : Array(ResultColumn)
    getter params : Array(Invalid::Param)
    getter? read_only : Bool
    # The table whose `Record` the query returns, when it selects a whole row.
    getter record : Schema::Table?
    # The statement with each named parameter replaced by `?N`, in order of
    # `params`; the driver binds by position.
    getter positional_sql : String
    # The table a write targets, when it is mapped, and the unique
    # constraints of it the write can violate.
    getter target : Schema::Table?
    getter violations : Array(Schema::Unique)
    # The declared clauses, checked, when the query has any.
    getter filtered : Filtered?

    def initialize(@query, @columns, @params, @read_only, @record, @positional_sql,
                   @target = nil, @violations = [] of Schema::Unique, @filtered = nil)
    end
  end

  # Types the result columns and parameters of one query: result columns
  # from SQLite's origin metadata and the schema, expressions and parameters
  # by a few rules over the tokens, the rest by annotation.
  class Analyzer
    TRANSACTION_WORDS = {"BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"}
    COMPARE           = {"=", "==", "!=", "<>", "<", "<=", ">", ">="}
    ARITHMETIC        = {"+", "-", "*", "/"}

    # Functions whose result type does not depend on their arguments.
    FIXED_RESULTS = {
      "count" => Type.new("Int64"), "row_number" => Type.new("Int64"), "rank" => Type.new("Int64"),
      "dense_rank" => Type.new("Int64"), "ntile" => Type.new("Int64"), "changes" => Type.new("Int64"),
      "total_changes" => Type.new("Int64"), "last_insert_rowid" => Type.new("Int64"), "random" => Type.new("Int64"),
      "total" => Type.new("Float64"), "avg" => Type.new("Float64", nil, true),
      # Date functions return NULL for input they cannot read.
      "date" => Type.new("String", nil, true), "time" => Type.new("String", nil, true),
      "datetime" => Type.new("String", nil, true), "strftime" => Type.new("String", nil, true),
      "unixepoch" => Type.new("Int64", nil, true), "julianday" => Type.new("Float64", nil, true),
      "json_object" => Type.new("String"), "json_array" => Type.new("String"), "json_group_array" => Type.new("String"),
      "json_group_object" => Type.new("String"), "json_quote" => Type.new("String"), "typeof" => Type.new("String"),
      "quote" => Type.new("String"), "hex" => Type.new("String"), "printf" => Type.new("String"),
      "format" => Type.new("String"), "group_concat" => Type.new("String", nil, true),
      "string_agg" => Type.new("String", nil, true),
      # `concat` skips NULL arguments; `timediff` is NULL for dates it cannot read.
      "concat" => Type.new("String"), "timediff" => Type.new("String", nil, true),
      # Interpolated between values, so never of their domain; NULL over no rows.
      "percentile" => Type.new("Float64", nil, true), "median" => Type.new("Float64", nil, true),
      "percentile_cont" => Type.new("Float64", nil, true),
    }
    # Functions that return text or an integer, NULL when their first
    # argument is (`concat_ws` skips its other arguments when NULL).
    TEXT_RESULTS    = {"lower", "upper", "trim", "ltrim", "rtrim", "substr", "substring", "replace", "unistr", "concat_ws"}
    INTEGER_RESULTS = {"length", "octet_length", "instr", "unicode"}
    DATE_FUNCTIONS  = {"date", "time", "datetime", "strftime", "julianday", "unixepoch"}

    @tokens : Array(SQL::Token)
    @aliases : Hash(String, String)
    @outer : Set(String)
    # The statement typed: the query as written, or with every `when`
    # clause and the first order switched on. Offsets are the same in both.
    @sql : String
    @text_domains : Hash(String, String)?

    def initialize(@schema : Schema, @query : Query, @errors : Array(Error))
      @sql = @query.clauses.empty? ? @query.sql : @query.assemble_full
      @tokens = SQL.tokenize(@sql)
      @aliases = SQL.aliases(@tokens)
      @outer = SQL.outer_tables(@tokens)
    end

    def analyze(connection : Database::Driver::Connection) : Analysis?
      clauses = Clauses.new(@query, @sql, @tokens, @errors)
      return unless check_text && clauses.check_structure

      shape = prepare(connection) || return
      columns, params = typed(shape) || return
      record = record_table(columns)
      return unless check_includes(columns, record)

      keyset = Keyset.build(@query, @sql, @tokens, columns, @schema, @errors) || return if @query.kind.page?
      filtered = clauses.check(connection, shape, params, keyset)
      return unless checked(clauses)

      target, violations = (Writes.analyze(@tokens, @schema) unless shape.read_only) || {nil, [] of Schema::Unique}
      Analysis.new(@query, columns, params, shape.read_only, record, positional(params), target, violations, filtered)
    end

    # What the statement's text alone shows: one statement, safe patterns,
    # and paths a document has.
    private def check_text : Bool
      check_tokens && check_like && check_paths
    end

    # Array parameters (`IN carray(:ids)`) are not supported yet with
    # declared clauses or pages.
    private def check_arrays(params : Array(Invalid::Param)) : Bool
      array = params.find(&.type.array) || return true
      return true if @query.clauses.empty? && !@query.kind.page?

      fail(@query.location, "param #{array.name}: array parameters are not supported yet in queries with declared clauses or pages")
      false
    end

    # Whether the clauses passed, and then what the statement does with
    # encrypted columns and blind indexes.
    private def checked(clauses : Clauses) : Bool
      !clauses.failed? && check_secrets
    end

    # A plaintext column being cleared (`from(:email, clear: true)`), as
    # `table.column`, if *name* is one: the next release drops it, and
    # a statement that names it would then fail in this one.
    private def cleared_column(qualifier : String?, name : String) : String?
      tables = qualifier ? [@aliases[qualifier.downcase]?].compact : @aliases.values.uniq!
      tables.each do |table|
        column = @schema.column(table, name) || next
        return "#{table}.#{column.name}" if column.cleared?
      end
      nil
    end

    private def dropping(column : String) : String
      "#{column} is being cleared (from(..., clear: true)), and the next release drops it; leave it out, and list the columns instead of *, so this release keeps working once it is gone"
    end

    # A result column that is a plaintext column being cleared, as `*`
    # selects it.
    private def check_cleared(columns : Array(ResultColumn)) : Bool
      columns.each do |column|
        table, origin = column.table, column.origin
        next unless table && origin && @schema.column(table, origin).try(&.cleared?)

        fail(@query.location, "column #{column.name}: #{dropping("#{table}.#{origin}")}")
        return false
      end
      true
    end

    # The result columns and parameters, each with its type.
    private def typed(shape : Database::Driver::Shape) : {Array(ResultColumn), Array(Invalid::Param)}?
      return unless check_kind(shape)

      columns = result_columns(shape) || return
      params = parameters(shape) || return
      {columns, params} if check_annotations(columns, params) && check_cleared(columns) && check_arrays(params)
    end

    private def prepare(connection : Database::Driver::Connection) : Database::Driver::Shape?
      connection.shape(@sql)
    rescue ex : Database::Error
      location = ex.offset.try { |offset| @query.location_at(@sql.byte_slice(0, offset).size) } || @query.location
      fail(location, ex.detail)
    end

    private def check_annotations(columns : Array(ResultColumn), params : Array(Invalid::Param)) : Bool
      used = columns.map { |column| "column #{column.name}" } + params.map { |param| "param #{param.name}" }
      unused = @query.annotations.keys - used
      return true if unused.empty?

      fail(@query.location, "annotation for #{unused.first}, which the query does not have")
      false
    end

    # Behaviour modules go into the query's own `Row`. A query that returns
    # whole records shares the record's behaviour file instead.
    private def check_includes(columns : Array(ResultColumn), record : Schema::Table?) : Bool
      mod, location = @query.includes.first? || return true
      if columns.empty?
        fail(location, "include #{mod}: the query returns no rows to include it in")
      elsif record
        fail(location, "include #{mod}: the query returns whole #{record.mod}::Record rows; include it in #{record.behaviour}, which every whole-row query shares")
      else
        return true
      end
      false
    end

    private def fail(location : Location, message : String) : Nil
      @errors << Error.new(location, "query #{@query.name}: #{message}")
      nil
    end

    private def check_tokens : Bool
      if (first = @tokens.first?) && TRANSACTION_WORDS.any? { |word| first.keyword?(word) }
        fail(@query.location, "transactions belong to the handle: a Writer is one transaction already")
        return false
      end
      depth = 0
      @tokens.each do |token|
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        problem = if depth == 0 && token.punct?(";")
                    "one statement per query"
                  elsif token.kind.param? && token.text.starts_with?('?')
                    "use named parameters, such as :customer_id, not ?"
                  end
        next unless problem
        fail(@query.location_at(token.offset), problem)
        return false
      end
      true
    end

    # Words that end a LIKE pattern, besides `)` and `,` at its own depth.
    LIKE_END = %w[AND OR ESCAPE THEN ELSE WHEN END] + SQL::CLAUSE_WORDS

    # User text in a LIKE pattern is a bound value, and its own `%` and `_`
    # would widen what matches (`50%` finds `500`). A pattern that holds a
    # parameter says `ESCAPE '\'`, so a value escaped with
    # `Punch::Database.escape_like` matches itself (point 5). The parameter
    # is a `Punch::LikeText`, which escapes when bound, so passing a
    # `String` does not compile.
    private def check_like : Bool
      @tokens.each_with_index do |token, i|
        if token.keyword?("GLOB") && like_pattern(i)[1]
          fail(@query.location_at(token.offset), %q(GLOB with a parameter in its pattern: `*`, `?`, and `[` in user text would match more than it says. Use LIKE … ESCAPE '' with the parameter as a Punch::LikeText))
          return false
        end
        next unless token.keyword?("LIKE")
        j, param = like_pattern(i)
        next unless param
        escape = @tokens[j + 1]? if @tokens[j]?.try(&.keyword?("ESCAPE"))
        next if escape && escape.kind.string? && escape.text == %q('\')
        fail(@query.location_at(token.offset), %q(LIKE with a parameter in its pattern needs ESCAPE '\', so `%` and `_` in user text match themselves (the parameter is a Punch::LikeText, which escapes it)))
        return false
      end
      true
    end

    # Where the pattern after the LIKE at *i* ends, and whether it holds a
    # parameter.
    private def like_pattern(i : Int32) : {Int32, Bool}
      depth = 0
      j = i + 1
      param = false
      while current = @tokens[j]?
        if current.punct?("(")
          depth += 1
        elsif current.punct?(")")
          break if depth == 0
          depth -= 1
        elsif depth == 0 && (current.punct?(",") || LIKE_END.any? { |word| current.keyword?(word) })
          break
        end
        param ||= current.kind.param?
        j += 1
      end
      {j, param}
    end

    # The parameters that feed a `LIKE` pattern or an FTS5 `MATCH`, to the
    # primitive that makes user text safe there: `Punch::LikeText`,
    # `Punch::FtsPhrase`. Empty (and reported) for one that also appears
    # elsewhere, since the primitive changes what is bound.
    private def text_domains : Hash(String, String)
      domains = {} of String => String
      inside = Set(Int32).new
      @tokens.each_with_index do |token, i|
        domain = token.keyword?("LIKE") ? "Punch::LikeText" : (token.keyword?("MATCH") ? "Punch::FtsPhrase" : next)
        j, _ = like_pattern(i)
        ((i + 1)...j).each do |index|
          next unless (param = @tokens[index]).kind.param?
          inside << index
          if (earlier = domains[param.text]?) && earlier != domain
            fail(@query.location_at(param.offset), "param #{param.text}: feeds a LIKE and a MATCH, which take different text; use two parameters")
          end
          domains[param.text] = domain
        end
      end
      @tokens.each_with_index do |token, index|
        next if !token.kind.param? || inside.includes?(index) || !domains.has_key?(token.text)
        fail(@query.location_at(token.offset), "param #{token.text}: feeds a #{domains[token.text] == "Punch::LikeText" ? "LIKE pattern" : "MATCH"} and is used elsewhere too, but it is bound as #{domains[token.text]}; use two parameters")
        domains.delete(token.text)
      end
      domains
    end

    private def check_kind(shape : Database::Driver::Shape) : Bool
      problem = case @query.kind
                in .one?, .many?
                  "returns no columns; use :exec or :execrows, or add RETURNING" if shape.columns.empty?
                in .page?
                  "changes rows; a page reads, and a write returns its rows with :many" unless shape.read_only
                in .exec?, .exec_rows?
                  if !shape.columns.empty?
                    "returns columns; use :one or :many"
                  elsif shape.read_only
                    "changes nothing; a query that reads uses :one or :many"
                  end
                end
      fail(@query.location, problem) if problem
      problem.nil?
    end

    # --- Result columns ------------------------------------------------------

    private def result_columns(shape : Database::Driver::Shape) : Array(ResultColumn)?
      if SQL.right_or_full_join?(@tokens)
        missing = shape.columns.map(&.name).reject { |name| @query.annotations.has_key?("column #{name}") }
        unless missing.empty?
          return fail(@query.location, "RIGHT or FULL JOIN: nullability is not derived; annotate every column (missing: #{missing.join(", ")})")
        end
      end
      items = SQL.select_items(@tokens, @sql)
      seen = Set(String).new
      columns = shape.columns.map { |column| result_column(column, items, seen) }
      columns.all? ? columns.compact : nil
    end

    private def result_column(column : Database::Driver::Column, items : Array(SQL::Item), seen : Set(String)) : ResultColumn?
      name = column.name
      unless QueryGen.identifier?(name)
        return fail(@query.location, "column #{name.inspect} is not a Crystal name; alias it, such as `AS #{QueryGen.underscore(name.gsub(/\W+/, "_")).strip('_')}`")
      end
      return fail(@query.location, "two columns are named #{name}; alias one of them") unless seen.add?(name)

      if type = @query.annotations["column #{name}"]?
        ResultColumn.new(name, type, Source::Annotation, column.table, column.origin)
      elsif (table = column.table) && (origin = column.origin) && !expression_item?(items, name) &&
            (type = @schema.column(table, origin).try(&.type))
        ResultColumn.new(name, type.nilable(type.nullable || @outer.includes?(table.downcase)), Source::Metadata, table, origin)
      elsif (item = items.find(&.name.==(name))) && (type = infer(item.tokens))
        ResultColumn.new(name, type, Source::Inferred, column.table, column.origin)
      else
        fail(@query.location, "column #{name}: type unknown, add `-- column #{name}: Type`")
      end
    end

    private def expression_item?(items : Array(SQL::Item), name : String) : Bool
      item = items.find(&.name.==(name)) || return false
      item.tokens.size > 1 && !qualified_column?(item.tokens)
    end

    # A query returning every column of one mapped table, in order and with
    # the table's types, returns that table's record.
    private def record_table(columns : Array(ResultColumn)) : Schema::Table?
      first = columns.first? || return
      table = first.table.try { |name| @schema.table(name) } || return
      return unless table.mod && table.record_columns.size == columns.size

      matches = table.record_columns.zip(columns).all? do |column, result|
        result.source.metadata? && result.table.try(&.downcase) == table.name.downcase &&
          result.origin == column.name && result.name == column.name && result.type == column.type
      end
      matches ? table : nil
    end

    # --- Expressions ---------------------------------------------------------

    private def column_type(qualifier : String?, name : String) : Type?
      tables = qualifier ? [@aliases[qualifier.downcase]?].compact : @aliases.values.uniq!
      tables.each do |table|
        if type = @schema.column(table, name).try(&.type)
          return type.nilable(type.nullable || @outer.includes?(table.downcase))
        end
      end
      nil
    end

    private def infer(tokens : Array(SQL::Token)) : Type?
      return if tokens.empty?
      return infer_parenthesized(tokens[1...-1]) if parenthesized?(tokens)

      concat = SQL.split_top(tokens, &.punct?("||"))
      return Type.new("String", nil, concat.any? { |part| infer(part).try(&.nullable) != false }) if concat.size > 1

      arithmetic = SQL.split_top(tokens, &.punct?("+", "-", "*", "/", "%"))
      return infer_arithmetic(arithmetic) if arithmetic.size > 1 && arithmetic.none?(&.empty?)

      arrow = SQL.split_top(tokens, &.punct?("->>"))
      return infer_path(arrow[0], arrow[1], true) if arrow.size == 2 && arrow[1].size == 1

      infer_term(tokens)
    end

    # `doc ->> 'path'` or `json_extract(doc, 'path')` over a composite's
    # document: the type of the field it reads (`Paths`); a path it
    # refuses is reported by `check_paths`.
    private def infer_path(base : Array(SQL::Token), literal : Array(SQL::Token), arrow : Bool) : Type?
      return unless literal.size == 1
      type = infer(base) || return

      case resolved = Paths.resolve(@schema, type, literal.first, arrow)
      in Type   then resolved
      in String then Type.new("String", nil, true)
      in Nil    then nil
      end
    end

    # Every path into a composite's document names fields it declares
    # (docs/composites.md, "Paths in queries").
    private def check_paths : Bool
      @tokens.each_index do |i|
        base, literal, arrow = path_at(i) || next
        type = infer(base) || next
        if (encrypted = type.encrypted) && type.domain.try { |domain| @schema.composites.has_key?(domain.lchop("Punch::Encrypted(").rchop(")")) }
          fail(@query.location_at(@tokens[i].offset), "#{encrypted} is an encrypted document, so a path into it reads ciphertext; select the column and read the field in Crystal")
          return false
        end
        problem = Paths.resolve(@schema, type, literal, arrow)
        next unless problem.is_a?(String)
        fail(@query.location_at(literal.offset), problem)
        return false
      end
      true
    end

    # The value, path, and form of a path read at token *i*: `x ->> 'p'` or
    # `json_extract(x, 'p')`.
    private def path_at(i : Int32) : {Array(SQL::Token), SQL::Token, Bool}?
      token = @tokens[i]
      if token.punct?("->>")
        literal = @tokens[i + 1]?
        return {operand_before(i), literal, true} if literal && i >= 1
      end
      return unless token.keyword?("json_extract") && @tokens[i + 1]?.try(&.punct?("("))

      args = SQL.split_top(@tokens[(i + 2)...SQL.matching(@tokens, i + 1)], &.punct?(","))
      {args[0], args[1].first, false} if args.size == 2 && args[1].size == 1
    end

    private def parenthesized?(tokens : Array(SQL::Token)) : Bool
      tokens.first.punct?("(") && tokens.last.punct?(")") && SQL.matching(tokens, 0) == tokens.size - 1
    end

    private def infer_parenthesized(inner : Array(SQL::Token)) : Type?
      return infer(inner) unless inner.first?.try &.keyword?("SELECT")

      # A scalar subquery is NULL when it finds no row.
      item = SQL.select_items(inner, @sql).first? || return
      saved = @aliases
      @aliases = saved.merge(SQL.aliases(inner))
      type = infer(item.tokens)
      @aliases = saved
      type.try(&.derived.nilable)
    end

    private def infer_arithmetic(parts : Array(Array(SQL::Token))) : Type?
      types = parts.map { |part| infer(part) }
      known = types.compact
      return unless known.size == types.size && known.all?(&.stored.in?("Int64", "Float64"))

      Type.new(known.any?(&.stored.==("Float64")) ? "Float64" : "Int64", nil, known.any?(&.nullable))
    end

    private def infer_term(tokens : Array(SQL::Token)) : Type?
      first = tokens.first
      return infer_atom(first) if tokens.size == 1
      return column_type(first.text, tokens[2].text) if qualified_column?(tokens)
      return infer_case(tokens) if first.keyword?("CASE")
      return Type.new("Int64") if first.keyword?("EXISTS") || (first.keyword?("NOT") && tokens[1]?.try(&.keyword?("EXISTS")))
      return unless first.kind.ident? && tokens[1]?.try(&.punct?("("))

      first.keyword?("CAST") ? infer_cast(tokens) : infer_function(tokens)
    end

    private def infer_atom(token : SQL::Token) : Type?
      case token.kind
      when .string? then Type.new("String")
      when .number? then Type.new(token.text.includes?('.') ? "Float64" : "Int64")
      when .ident?  then token.keyword?("NULL", "TRUE", "FALSE") ? nil : column_type(nil, token.text)
      end
    end

    private def qualified_column?(tokens : Array(SQL::Token)) : Bool
      tokens.size == 3 && tokens[0].kind.ident? && tokens[1].punct?(".") && tokens[2].kind.ident?
    end

    # `CAST(x AS INTEGER)`: the declared type, nilable when *x* is.
    private def infer_cast(tokens : Array(SQL::Token)) : Type?
      close = SQL.matching(tokens, 1)
      as_index = (2...close).find { |index| tokens[index].keyword?("AS") } || return
      stored = QueryGen.stored_type(tokens[(as_index + 1)...close].join(" ", &.text)) || return
      inner = infer(tokens[2...as_index])
      Type.new(stored, nil, inner.nil? || inner.nullable)
    end

    private def infer_function(tokens : Array(SQL::Token)) : Type?
      close = SQL.matching(tokens, 1)
      return unless close == tokens.size - 1 || tokens[close + 1]?.try(&.keyword?("OVER", "FILTER"))

      arguments = SQL.split_top(tokens[2...close], &.punct?(","))
      arguments.first.shift if arguments.first.first?.try &.keyword?("DISTINCT")
      infer_call(tokens.first.text.downcase, arguments)
    end

    private def infer_call(function : String, arguments : Array(Array(SQL::Token))) : Type?
      if fixed = FIXED_RESULTS[function]?
        return fixed
      end
      return infer_choice(function, arguments) if function.in?("coalesce", "ifnull", "iif", "if", "json_extract")

      first = infer(arguments[0])
      if function.in?(TEXT_RESULTS) || function.in?(INTEGER_RESULTS)
        return Type.new(function.in?(TEXT_RESULTS) ? "String" : "Int64", nil, first.nil? || first.nullable)
      end

      case function
      when "sum"                       then first.try { |type| Type.new(type.stored, nil, true) }    # NULL over no rows
      when "min", "max"                then arguments.size == 1 ? first.try(&.derived.nilable) : nil # the scalar forms compare several values
      when "nullif", "percentile_disc" then first.try(&.derived.nilable)                             # percentile_disc: one of the values
      when "abs", "round"              then first.try(&.bare)
      end
    end

    # The first value that is not NULL, the value of the first condition
    # that holds, or the field a path names.
    private def infer_choice(function : String, arguments : Array(Array(SQL::Token))) : Type?
      return (arguments.size == 2 ? infer_path(arguments[0], arguments[1], false) : nil) if function == "json_extract"

      function.in?("iif", "if") ? infer_iif(arguments) : infer_coalesce(arguments)
    end

    private def infer_coalesce(arguments : Array(Array(SQL::Token))) : Type?
      types = arguments.map { |argument| infer(argument) }
      known = types.compact
      first = known.first? || return
      domain = known.all?(&.domain.==(first.domain)) && !first.encrypted ? first.domain : nil
      Type.new(first.stored, domain, types.all? { |type| type.nil? || type.nullable })
    end

    private def infer_case(tokens : Array(SQL::Token)) : Type?
      branches, has_else = case_branches(tokens)
      infer_branches(branches, has_else)
    end

    # `iif(c1, v1, c2, v2, …, else)`: a CASE in a call. Without the last
    # value (an even number of arguments), NULL when no condition holds.
    private def infer_iif(arguments : Array(Array(SQL::Token))) : Type?
      return if arguments.size < 2

      branches = (1...arguments.size).step(2).map { |index| arguments[index] }.to_a
      has_else = arguments.size.odd?
      branches << arguments.last if has_else
      infer_branches(branches, has_else)
    end

    private def infer_branches(branches : Array(Array(SQL::Token)), has_else : Bool) : Type?
      types = branches.map { |branch| infer(branch) }
      known = types.compact
      return if known.empty? || known.size != types.size || known.map(&.stored).uniq!.size != 1

      domain = known.all?(&.domain.==(known.first.domain)) && !known.first.encrypted ? known.first.domain : nil
      Type.new(known.first.stored, domain, !has_else || known.any?(&.nullable))
    end

    # The result expressions of a CASE (after each THEN and the ELSE), and
    # whether it has an ELSE.
    private def case_branches(tokens : Array(SQL::Token)) : {Array(Array(SQL::Token)), Bool}
      branches = [] of Array(SQL::Token)
      current : Array(SQL::Token)? = nil
      depth = 0
      has_else = false
      tokens[1..].each do |token|
        depth += 1 if token.punct?("(") || token.keyword?("CASE")
        depth -= 1 if token.punct?(")") || (token.keyword?("END") && depth > 0)
        if depth == 0 && token.keyword?("THEN", "ELSE")
          has_else ||= token.keyword?("ELSE")
          branches << (current = [] of SQL::Token)
        elsif depth == 0 && token.keyword?("WHEN", "END")
          current = nil
        else
          current.try &.<<(token)
        end
      end
      {branches, has_else}
    end

    # --- Parameters ----------------------------------------------------------

    private def parameters(shape : Database::Driver::Shape) : Array(Invalid::Param)?
      params = shape.parameters.compact.map { |raw| parameter(raw[1..]) }
      params.all? ? params.compact : nil
    end

    private def parameter(name : String) : Invalid::Param?
      occurrences = @tokens.each_index.select { |index| @tokens[index].kind.param? && @tokens[index].text == name }.to_a
      location = @query.location_at(occurrences.first?.try { |index| @tokens[index].offset } || 0)
      unless QueryGen.identifier?(name) && name != "db"
        return fail(location, "parameter :#{name} cannot be a Crystal argument name; rename it")
      end

      domain = (@text_domains ||= text_domains)[name]?
      if type = @query.annotations["param #{name}"]?
        return Invalid::Param.new(name, text_type(type, domain), Source::Annotation)
      end
      return Invalid::Param.new(name, text_type(Type.new("String"), domain), Source::Inferred) if domain

      uses = occurrences.compact_map { |index| blind_use(index).try { |use| {index, use} } }
      return blind_param(name, occurrences, uses) unless uses.empty?
      return if compared_with_ciphertext(name, occurrences)

      # Every occurrence may give a type; the first that does wins.
      type = occurrences.each.compact_map { |index| infer_param(index) }.first?
      if occurrences.any? { |index| carray_argument?(index) } && !type.try(&.array)
        return fail(location, "param #{name}: an array parameter takes its type from the column it is compared with, so write `column IN carray(:#{name})`")
      end
      return fail(location, "param #{name}: type unknown, add `-- param #{name}: Type`") unless type

      Invalid::Param.new(name, type, Source::Inferred)
    end

    # Whether the parameter is compared with an encrypted column, which it
    # never equals (reported); writing to one is fine.
    private def compared_with_ciphertext(name : String, occurrences : Array(Int32)) : Bool
      occurrences.each do |index|
        next if insert_target(index) || set_target(index)
        if column = (array_type(index) || comparison_type(index) || distinct_type(index) || optional_type(index)).try(&.encrypted)
          fail(@query.location_at(@tokens[index].offset), "param #{name}: compared with #{column}, which is encrypted; its stored values are ciphertext, different every time, so they never equal a value")
          return true
        end
      end
      false
    end

    # How the parameter at *index* meets a blind index: written to one
    # (`:write`), compared with `column = :param` (`:lookup`), or anything
    # else (`:refused`); `nil` when it does not.
    private def blind_use(index : Int32) : {Type, Symbol}?
      if type = (insert_target(index) || set_target(index)).try { |target| target if target.blind }
        return {type, :write}
      end
      if index >= 1 && @tokens[index - 1].punct?("=", "==") && operand_end?(index) && (type = infer(operand_before(index - 1))) && type.blind
        return {type.nilable(false).copy_with(lookup: true), :lookup}
      end

      (comparison_type(index) || distinct_type(index) || optional_type(index)).try { |other| {other, :refused} if other.blind }
    end

    # Whether the parameter at *index* ends its operand, as `= :param`
    # must for its rewrite into `IN (…)`.
    private def operand_end?(index : Int32) : Bool
      following = @tokens[index + 1]? || return true
      return true if following.punct?(")", ",")

      following.kind.ident? && !following.keyword?("COLLATE", "IS", "NOT", "LIKE", "GLOB", "IN", "BETWEEN")
    end

    # A parameter written to a blind index takes the encrypted column's
    # `T` and binds its hash; one compared with it takes `T` too and binds
    # the hashes under every key. Either way every occurrence must be the
    # same use, since a parameter binds one value.
    private def blind_param(name : String, occurrences : Array(Int32), uses : Array({Int32, {Type, Symbol}})) : Invalid::Param?
      index, found = uses.find(&.[1][1].==(:refused)) || uses.first
      type, use = found
      column = type.blind
      location = @query.location_at(@tokens[index].offset)
      if use == :refused
        return fail(location, "param #{name}: #{column} is a blind index, so compare it only as `#{column.try(&.split('.').last)} = :#{name}`, or `#{column.try(&.split('.').last)} IN carray(:#{name})` for several, column first; it holds hashes, which have no order and match only the whole value")
      end
      if uses.size != occurrences.size || uses.any?(&.[1][1].!=(use))
        return fail(location, "param #{name}: #{use == :lookup ? "compared with" : "written to"} #{column}, a blind index, so it binds #{use == :lookup ? "hashes" : "a hash"}; use another parameter for its other places")
      end

      Invalid::Param.new(name, type, Source::Inferred)
    end

    # SQL that cannot work on an encrypted column or a blind index:
    # ciphertext differs on every write, and a blind index matches only a
    # parameter's hashes. Comparing either with anything else, `LIKE`, `IN`,
    # `BETWEEN`, and sorting or grouping by either are valid SQL that
    # silently finds nothing, or nothing in order.
    private def check_secrets : Bool
      @tokens.each_with_index do |token, i|
        next unless token.kind.ident?
        next if @tokens[i + 1]?.try(&.punct?(".", "("))
        qualifier = @tokens[i - 2].text if i >= 2 && @tokens[i - 1].punct?(".")
        if cleared = cleared_column(qualifier, token.text)
          fail(@query.location_at(token.offset), dropping(cleared))
          return false
        end
        type = column_type(qualifier, token.text) || next
        column = type.secret_column || next
        problem = secret_problem(i, type, column) || next
        fail(@query.location_at(token.offset), problem)
        return false
      end
      # The statement checked has the first order on; the others sort too.
      @query.orders.each do |order|
        SQL.tokenize(order.sql).each do |token|
          next unless token.kind.ident?
          column = column_type(nil, token.text).try(&.secret_column) || next
          fail(order.location, "order #{order.key}: #{column} #{column_type(nil, token.text).try(&.encrypted) ? "is encrypted" : "is a blind index"}, so sorting by it means nothing")
          return false
        end
      end
      true
    end

    private def secret_problem(i : Int32, type : Type, column : String) : String?
      what = type.encrypted ? "is encrypted, and its ciphertext differs on every write" : "is a blind index, whose hashes only `#{column.split('.').last} = :param` and `#{column.split('.').last} IN carray(:param)` find"
      if compare?(@tokens[i + 1]?)
        compared_problem(i, type, column, what)
      elsif compare?(before(i))
        assigned_problem(i, column, what)
      elsif type.blind && carray_lookup?(i)
        nil
      elsif operator = matching_operator(i)
        "#{column} #{what}; #{operator} on it never matches"
      elsif sorted?(i)
        "#{column} #{what}, so sorting or grouping by it means nothing"
      end
    end

    private def compare?(token : SQL::Token?) : Bool
      !!token.try { |op| op.kind.punct? && COMPARE.includes?(op.text) }
    end

    # The token before the column reference ending at *i*, its qualifier included.
    private def before(i : Int32) : SQL::Token?
      start = qualified_start(i)
      @tokens[start - 1] if start >= 1
    end

    # `column = …`: an assignment, a blind index's lookup, or a comparison.
    private def compared_problem(i : Int32, type : Type, column : String, what : String) : String?
      return if set_assignment?(qualified_start(i))
      return if type.blind && @tokens[i + 1].punct?("=", "==") && @tokens[i + 2]?.try(&.kind.param?)

      "#{column} #{what}; comparing it with anything else never matches"
    end

    # `… = column`: assigned to a column, or compared.
    private def assigned_problem(i : Int32, column : String, what : String) : String?
      start = qualified_start(i)
      unless before(i).try(&.punct?("=")) && start >= 2 && set_assignment?(start - 2)
        return "#{column} #{what}; comparing anything with it never matches"
      end

      # `DO UPDATE SET note = excluded.note` keeps a value in its column.
      return if @tokens[start - 2].text.compare(@tokens[i].text, case_insensitive: true) == 0

      "#{column} #{what}; it opens only in its own column, so assign it nothing but a parameter"
    end

    # `LIKE`, `IN`, … (or `NOT LIKE`, …) after the column at *i*.
    # `column [NOT] IN carray(:param)`, which binds hashes for a blind index.
    private def carray_lookup?(i : Int32) : Bool
      j = @tokens[i + 1]?.try(&.keyword?("NOT")) ? i + 2 : i + 1
      !!@tokens[j]?.try(&.keyword?("IN")) && !!@tokens[j + 3]?.try(&.kind.param?) && carray_argument?(j + 3)
    end

    private def matching_operator(i : Int32) : String?
      operator = @tokens[i + 1]?.try { |word| word.keyword?("NOT") ? @tokens[i + 2]? : word }
      operator.text.upcase if operator && operator.keyword?("LIKE", "GLOB", "MATCH", "REGEXP", "IN", "BETWEEN")
    end

    # Where the column reference ending at *i* starts: at its qualifier.
    private def qualified_start(i : Int32) : Int32
      i >= 2 && @tokens[i - 1].punct?(".") ? i - 2 : i
    end

    # Whether the column at *start* is the target of `SET column = …`.
    private def set_assignment?(start : Int32) : Bool
      start >= 1 && @tokens[start - 1].keyword?("SET") || (start >= 1 && @tokens[start - 1].punct?(",") && !!written_table && set_list?(start - 1))
    end

    # Whether the `,` at *comma* separates assignments of a `SET`.
    private def set_list?(comma : Int32) : Bool
      depth = 0
      (comma - 1).downto(0) do |k|
        token = @tokens[k]
        depth += 1 if token.punct?(")")
        depth -= 1 if token.punct?("(")
        return false if depth < 0
        next unless depth == 0
        return true if token.keyword?("SET")
        return false if token.keyword?("SELECT", "FROM", "WHERE", "VALUES", "RETURNING")
      end
      false
    end

    # Whether the token at *i* is in an `ORDER BY` or `GROUP BY` list,
    # including a window's.
    private def sorted?(i : Int32) : Bool
      depth = 0
      (i - 1).downto(0) do |k|
        token = @tokens[k]
        depth += 1 if token.punct?(")")
        if token.punct?("(")
          return false if depth == 0
          depth -= 1
        end
        next unless depth == 0
        return k >= 1 && @tokens[k - 1].keyword?("ORDER", "GROUP") if token.keyword?("BY")
        return false if token.keyword?("SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "ON", "SET", "VALUES", "RETURNING")
      end
      false
    end

    # The type of a parameter in a `LIKE` or `MATCH`: the text primitive.
    private def text_type(type : Type, domain : String?) : Type
      domain ? Type.new("String", domain, type.nullable) : type
    end

    private def infer_param(index : Int32) : Type?
      array_type(index) || context_type(index) || insert_target(index) || set_target(index) || comparison_type(index) || distinct_type(index) || optional_type(index)
    end

    # `id > coalesce(:after, 0)`: a parameter that may be `NULL` in place of
    # a value compared with a column, such as an optional cursor. It takes
    # the other side's type, nilable.
    private def optional_type(index : Int32) : Type?
      return unless index >= 2 && @tokens[index - 1].punct?("(")
      return unless @tokens[index - 2].keyword?("coalesce", "ifnull")

      close = SQL.matching(@tokens, index - 1)
      if index >= 3 && (op = @tokens[index - 3]).kind.punct? && COMPARE.includes?(op.text)
        infer(operand_before(index - 3)).try(&.nilable)
      elsif (op = @tokens[close + 1]?) && op.kind.punct? && COMPARE.includes?(op.text)
        infer(operand_after(close + 1)).try(&.nilable)
      end
    end

    # `id IN carray(:ids)`: an array of the compared column's type, bound
    # as one parameter (`sqlite3_carray_bind_v2`). Against a blind index,
    # the elements' hashes under every key.
    private def array_type(index : Int32) : Type?
      return unless carray_argument?(index) && @tokens[index - 3].keyword?("IN")

      owner = index >= 4 && @tokens[index - 4].keyword?("NOT") ? index - 4 : index - 3
      infer(operand_before(owner)).try { |type| type.nilable(false).copy_with(array: true, lookup: !type.blind.nil?) }
    end

    # Whether the parameter at *index* is the one argument of `carray(…)`.
    private def carray_argument?(index : Int32) : Bool
      index >= 3 && @tokens[index - 1].punct?("(") && @tokens[index - 2].keyword?("carray") && !!@tokens[index + 1]?.try(&.punct?(")"))
    end

    # `parent_id IS NOT DISTINCT FROM :parent`: compares like `=`, with
    # NULL equal to NULL, so the parameter takes the other side's type,
    # nilable. Either side; `IS DISTINCT FROM` too.
    private def distinct_type(index : Int32) : Type?
      if index >= 4 && @tokens[index - 1].keyword?("FROM") && @tokens[index - 2].keyword?("DISTINCT")
        is = @tokens[index - 3].keyword?("NOT") ? index - 4 : index - 3
        return infer(operand_before(is)).try(&.nilable) if is >= 1 && @tokens[is].keyword?("IS")
      end
      return unless @tokens[index + 1]?.try(&.keyword?("IS"))

      j = index + 2
      j += 1 if @tokens[j]?.try(&.keyword?("NOT"))
      return unless @tokens[j]?.try(&.keyword?("DISTINCT")) && @tokens[j + 1]?.try(&.keyword?("FROM"))

      infer(operand_after(j + 1)).try(&.nilable)
    end

    # Positions that fix the type: LIMIT, `||`, LIKE, and date functions.
    private def context_type(index : Int32) : Type?
      previous = index > 0 ? @tokens[index - 1] : nil
      following = @tokens[index + 1]?
      return Type.new("Int64") if previous.try &.keyword?("LIMIT", "OFFSET")
      return Type.new("String") if previous.try(&.punct?("||")) || following.try(&.punct?("||"))
      return Type.new("String") if previous.try(&.keyword?("LIKE", "GLOB"))

      if previous.try(&.punct?("(")) && (function = @tokens[index - 2]?) && DATE_FUNCTIONS.any? { |name| function.keyword?(name) }
        Type.new("String")
      end
    end

    # `SET column = :value` in an UPDATE or an upsert: the column's type.
    private def set_target(index : Int32) : Type?
      return unless index >= 3 && @tokens[index - 1].punct?("=") && (column = @tokens[index - 2]).kind.ident?
      return unless @tokens[index - 3].keyword?("SET") || @tokens[index - 3].punct?(",")

      table = written_table || return
      @schema.column(table, column.text).try(&.type)
    end

    # The table an UPDATE or INSERT writes to; for an upsert
    # (`INSERT INTO t … DO UPDATE SET`) the INSERT's.
    private def written_table : String?
      start = @tokens.index(&.keyword?("INTO")) || @tokens.index(&.keyword?("UPDATE")) || return
      j = start + 1
      j += 2 if @tokens[j]?.try(&.keyword?("OR")) # UPDATE OR IGNORE
      @tokens[j]?.try(&.text)
    end

    # The other side of a comparison, arithmetic, IN, or BETWEEN decides.
    private def comparison_type(index : Int32) : Type?
      previous = index > 0 ? @tokens[index - 1] : nil
      following = @tokens[index + 1]?
      if previous && previous.kind.punct? && (COMPARE.includes?(previous.text) || ARITHMETIC.includes?(previous.text))
        type = infer(operand_before(index - 1))
        return ARITHMETIC.includes?(previous.text) ? type.try(&.bare.nilable(false)) : type.try(&.nilable(false)) if type
      end
      if owner = in_list_owner(index)
        return infer(operand_before(owner)).try(&.nilable(false))
      end
      if following && following.kind.punct? && COMPARE.includes?(following.text)
        return infer(operand_after(index + 1)).try(&.nilable(false))
      end

      between_owner(index).try { |between| infer(operand_before(between)).try(&.nilable(false)) }
    end

    # For `x IN (:a, :b)`, the index of `IN`.
    private def in_list_owner(index : Int32) : Int32?
      j = index - 1
      while j >= 0 && (@tokens[j].punct?(",") || @tokens[j].kind.param?)
        j -= 1
      end
      return unless j >= 1 && @tokens[j].punct?("(") && @tokens[j - 1].keyword?("IN")

      j - 1
    end

    # For `x BETWEEN :a AND :b`, the index of `BETWEEN`.
    private def between_owner(index : Int32) : Int32?
      return if index < 1

      if @tokens[index - 1].keyword?("BETWEEN")
        index - 1
      elsif @tokens[index - 1].keyword?("AND") && index >= 3 && @tokens[index - 3].keyword?("BETWEEN")
        index - 3
      end
    end

    # The primary expression ending just before index *op*.
    private def operand_before(op : Int32) : Array(SQL::Token)
      operand = simple_operand_before(op)
      # `doc ->> 'path' = :param`: the path is the operand.
      start = op - operand.size
      if start >= 2 && @tokens[start - 1].punct?("->>")
        return simple_operand_before(start - 1) + [@tokens[start - 1]] + operand
      end
      operand
    end

    private def simple_operand_before(op : Int32) : Array(SQL::Token)
      j = op - 1
      return [] of SQL::Token if j < 0
      return @tokens[(j - 2)..j] if j >= 2 && @tokens[j - 1].punct?(".")
      return [@tokens[j]] unless @tokens[j].punct?(")")

      depth = 0
      k = j
      while k >= 0
        depth += 1 if @tokens[k].punct?(")")
        depth -= 1 if @tokens[k].punct?("(")
        break if depth == 0
        k -= 1
      end
      k -= 1 if k > 0 && @tokens[k - 1].kind.ident? # a function name
      @tokens[k..j]
    end

    private def operand_after(op : Int32) : Array(SQL::Token)
      operand = simple_operand_after(op)
      # `:param = doc ->> 'path'`: the path is the operand.
      after = op + operand.size + 1
      if @tokens[after]?.try(&.punct?("->>")) && (literal = @tokens[after + 1]?)
        return operand + [@tokens[after], literal]
      end
      operand
    end

    private def simple_operand_after(op : Int32) : Array(SQL::Token)
      j = op + 1
      return [] of SQL::Token if j >= @tokens.size
      return @tokens[j..(j + 2)] if @tokens[j + 1]?.try(&.punct?("."))
      return @tokens[j..SQL.matching(@tokens, j + 1)] if @tokens[j + 1]?.try(&.punct?("("))

      [@tokens[j]]
    end

    # `INSERT INTO t (a, b) VALUES (:a, :b)`: the column at the same position.
    private def insert_target(index : Int32) : Type?
      table, names, values = insert_columns || return
      return unless index > values

      # The row of VALUES that holds the parameter.
      open = (values + 1...index).to_a.reverse.find { |i| @tokens[i].punct?("(") && SQL.matching(@tokens, i) > index } || return
      cells = SQL.split_top(@tokens[(open + 1)...SQL.matching(@tokens, open)], &.punct?(","))
      position = cells.index { |cell| cell.size == 1 && cell[0].offset == @tokens[index].offset } || return
      @schema.column(table, names[position]? || return).try(&.type)
    end

    # The target table, the listed columns, and the index of VALUES.
    private def insert_columns : {String, Array(String), Int32}?
      insert = @tokens.index(&.keyword?("INSERT", "REPLACE")) || return
      into = (insert...@tokens.size).find { |i| @tokens[i].keyword?("INTO") } || return
      values = @tokens.index(&.keyword?("VALUES")) || return
      table = @tokens[into + 1]?.try(&.text) || return
      open = into + 2
      open += 2 if @tokens[open]?.try(&.keyword?("AS"))
      return unless @tokens[open]?.try(&.punct?("("))

      names = SQL.split_top(@tokens[(open + 1)...SQL.matching(@tokens, open)], &.punct?(",")).map(&.first.text)
      {table, names, values}
    end

    # The statement with every named parameter replaced by `?N`, and each
    # blind index lookup by its form for several hashes (`Analyzer.lookup`).
    private def positional(params : Array(Invalid::Param)) : String
      numbers = params.each_with_index.to_h { |param, index| {param.name, index + 1} }
      lookups = params.select { |param| param.type.lookup && !param.type.array }.map(&.name).to_set
      Analyzer.positional(@sql, @tokens, lookups) { |name| "?#{numbers[name]}" }
    end

    # *sql* with each parameter replaced by what the block gives for its
    # name. A parameter in *lookups* is compared with a blind index as
    # `column = :param` (checked before), and binds the column's hashes
    # under every key as an array, so its `= :param` becomes
    # `IN carray(:param)`.
    def self.positional(sql : String, tokens : Array(SQL::Token), lookups : Set(String), & : String -> String) : String
      String.build do |io|
        position = 0
        tokens.each_with_index do |token, i|
          next unless token.kind.param?
          if lookups.includes?(token.text) && i >= 1
            io << sql[position...tokens[i - 1].offset] << "IN carray(" << yield(token.text) << ")"
          else
            io << sql[position...token.offset] << yield(token.text)
          end
          position = token.offset + token.size
        end
        io << sql[position..]
      end
    end
  end
end
