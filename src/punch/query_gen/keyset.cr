module Punch::QueryGen
  # The keyset of a `:page` query: each order's sort terms, the condition
  # that continues after a row in that order, and where in the statement it
  # goes. A page continues from the last row's sort values, so every term is
  # a selected, non-NULL table column, and the last one tells rows apart.
  class Keyset
    # A sort term: what the condition compares, the result column the
    # cursor takes its value from, and the direction.
    record Term, expression : String, column : ResultColumn, descending : Bool

    # One order: its clause (`nil` for the statement's own ORDER BY), its
    # terms, and the condition after a cursor, with `?` for the cursor value
    # at each of *indexes*.
    record Key, order : Clause?, terms : Array(Term), sql : String, indexes : Array(Int32) do
      def reversed? : Bool
        order.try(&.reversed?) || false
      end
    end

    getter keys : Array(Key)
    # Where the condition goes: the statement's line, and the column on it,
    # `nil` to go after the line.
    getter line : Int32
    getter column : Int32?

    def initialize(@keys, @line, @column)
    end

    # Checks a `:page` query and finds its keyset. *sql* and *tokens* are
    # the statement the analyzer typed, *columns* its result. `nil` after
    # adding the errors found.
    def self.build(query : Query, sql : String, tokens : Array(SQL::Token), columns : Array(ResultColumn), schema : Schema,
                   errors : Array(Error)) : Keyset?
      Builder.new(query, sql, tokens, columns, schema, errors).build
    end

    # The statement with *on* switched on and the condition of *key* in
    # place, as SQLite prepares it to check the key.
    def assemble(query : Query, on : Enumerable(Clause), key : Key) : String
      "#{splice(query, on, key.sql)}\nLIMIT ?"
    end

    # The column that tells rows apart, which the by-key variant of the
    # query compares: the key of the first order, whose last term is
    # distinct (checked in `build`).
    def row_key : Term
      keys.first.terms.last
    end

    # The condition of the by-key variant: the row with this key.
    def by_key_sql : String
      "AND #{row_key.expression} = ?"
    end

    # The statement with *on* switched on and the by-key condition in
    # place of the cursor's, as SQLite prepares it to check the variant.
    def assemble_by_key(query : Query, on : Enumerable(Clause)) : String
      splice(query, on, by_key_sql)
    end

    private def splice(query : Query, on : Enumerable(Clause), condition : String) : String
      lines = query.assemble(on).lines(chomp: false)
      text = lines[line]
      lines[line] = if at = column
                      "#{text[0...at]}\n#{condition}\n#{text[at..]}"
                    else
                      "#{text.chomp}\n#{condition}#{text.ends_with?('\n') ? "\n" : ""}"
                    end
      lines.join.rstrip
    end

    private class Builder
      def initialize(@query : Query, @sql : String, @tokens : Array(SQL::Token), @columns : Array(ResultColumn),
                     @schema : Schema, @errors : Array(Error))
        @aliases = SQL.aliases(@tokens)
        @items = SQL.select_items(@tokens, @sql)
        @top = SQL.top_level(@tokens)
      end

      def build : Keyset?
        if word = @top.map { |i| @tokens[i] }.find(&.keyword?("UNION", "EXCEPT", "INTERSECT"))
          return fail(location(word), "a page continues one SELECT; #{word.text.upcase} joins several")
        end
        if word = @top.map { |i| @tokens[i] }.find(&.keyword?("LIMIT", "OFFSET"))
          return fail(location(word), "a page takes its size from the method's `limit:`, and continues by cursor; remove #{word.text.upcase}")
        end

        where = @top.reverse_each.find { |i| @tokens[i].keyword?("WHERE") } ||
                return fail(@query.location, "a page continues by a condition in WHERE; write one, `WHERE true` if nothing else")
        last = @tokens[SQL.condition_end(@tokens, where)]
        line, column = position(last.offset + last.size)
        orders = @query.orders.empty? ? [{nil, own_order || return}] : @query.orders.map { |clause| {clause, clause.sql} }
        keys = orders.map { |clause, text| key(clause, text) }
        return unless keys.all?

        # Each declared order read backwards too (`direction: :desc`); its
        # terms are the same columns, so it passes where the order did.
        keys = keys.compact.flat_map do |key|
          backwards = key.order.try(&.reversed)
          backwards ? [key, key(backwards, backwards.sql) || return] : [key]
        end
        Keyset.new(keys, line, column)
      end

      private def fail(location : Location, message : String) : Nil
        @errors << Error.new(location, "query #{@query.name}: #{message}")
        nil
      end

      private def location(token : SQL::Token) : Location
        @query.location_at(token.offset)
      end

      # The line and column after *offset*; the column is `nil` when only
      # blanks or a comment follow on that line.
      private def position(offset : Int32) : {Int32, Int32?}
        before = @sql[0...offset]
        line = before.count('\n')
        start = (before.rindex('\n') || -1) + 1
        rest = @sql[offset..].lines.first? || ""
        {line, rest.blank? || rest.lstrip.starts_with?("--") ? nil : offset - start}
      end

      # The statement's own ORDER BY, for a query without `-- order` lines.
      private def own_order : String?
        index = @top.find { |i| @tokens[i].keyword?("ORDER") && @tokens[i + 1]?.try(&.keyword?("BY")) } ||
                return fail(@query.location, "a page needs an order, ORDER BY … or `-- order` lines, that ends with a key")
        first = @tokens[index]
        @sql[first.offset..].rstrip
      end

      private def key(clause : Clause?, text : String) : Key?
        where = clause.try(&.location) || @query.location
        label = clause.try { |order| "order #{order.key}#{order.reversed? ? " desc" : ""}" } || "the order"
        tokens = SQL.tokenize(text)[2..]
        terms = SQL.split_top(tokens, &.punct?(",")).map { |part| term(part, text, where, label) }
        return unless terms.all?

        terms = terms.compact
        return unless distinct?(terms.last, where, label)

        sql, indexes = condition(terms)
        Key.new(clause, terms, sql, indexes)
      end

      private def term(tokens : Array(SQL::Token), text : String, where : Location, label : String) : Term?
        tokens = tokens.dup
        tokens.pop(2) if tokens.size > 2 && tokens[-2].keyword?("NULLS")
        descending = tokens.last?.try(&.keyword?("DESC")) || false
        tokens.pop if tokens.last?.try(&.keyword?("ASC", "DESC"))
        return fail(where, "#{label}: a sort term is missing") if tokens.empty?

        written = text[tokens.first.offset...tokens.last.offset + tokens.last.size]
        collate = tokens.size > 2 && tokens[-2].keyword?("COLLATE") ? " COLLATE #{tokens.last.text}" : ""
        core = collate.empty? ? tokens : tokens[0...-2]
        column, expression = resolve(core, written) || return fail(where, "#{label}: sorts by #{written}; a page continues after the last row's sort values, so sort by selected columns of a table")
        problem(column).try { |found| return fail(where, "#{label}: #{found}") }
        Term.new(expression + collate, column, descending)
      end

      # Why a cursor cannot carry *column*'s value, if it cannot.
      private def problem(column : ResultColumn) : String?
        name = column.name
        if column.table.nil? || column.origin.nil?
          "sorts by #{name}, which is computed; a page compares sort values in WHERE, so sort by columns of a table"
        elsif column.type.nullable
          "sorts by #{name}, which can be NULL; a page cannot continue after a NULL, so sort by a NOT NULL column"
        elsif column.type.encrypted
          "sorts by #{name}, which is encrypted; ciphertext has no order"
        elsif column.type.blind
          "sorts by #{name}, a blind index; its hashes have no order"
        elsif column.type.stored == "Bytes"
          "sorts by #{name}, a BLOB, which a cursor does not carry"
        elsif sqlite_time?(column)
          "sorts by #{name}, whose default writes SQLite's datetime() text, which sorts apart from the times Punch writes, so a page could skip rows; drop the default and set the time in the Command"
        end
      end

      # The result column a term sorts by, and what the condition compares:
      # the term as written, or the expression behind an alias.
      private def resolve(core : Array(SQL::Token), written : String) : {ResultColumn, String}?
        if core.size == 1 && core[0].kind.ident?
          by_name(core[0].text)
        elsif core.size == 3 && core[1].punct?(".")
          table = @aliases[core[0].text.downcase]? || return
          column = @columns.find { |candidate| same?(candidate.table, table) && same?(candidate.origin, core[2].text) }
          {column, written.sub(/\s+COLLATE\s+\S+\z/i, "")} if column
        end
      end

      # A bare name: a result column's name (an alias compares the
      # expression behind it), else the one result column from a table
      # column of that name.
      private def by_name(name : String) : {ResultColumn, String}?
        if column = @columns.find { |candidate| same?(candidate.name, name) }
          item = @items.find { |candidate| same?(candidate.name, name) }
          expression = item.try { |found| @sql[found.tokens.first.offset...found.tokens.last.offset + found.tokens.last.size] }
          return {column, expression || qualified(column) || name}
        end
        matches = @columns.select { |candidate| same?(candidate.origin, name) }
        {matches.first, qualified(matches.first) || name} if matches.size == 1
      end

      private def same?(a : String?, b : String) : Bool
        !!a.try(&.compare(b, case_insensitive: true).zero?)
      end

      # A `Time` column that SQLite fills with its own text form.
      private def sqlite_time?(column : ResultColumn) : Bool
        return false unless column.type.domain == "Time"

        default = column.table.try { |table| column.origin.try { |origin| @schema.column(table, origin) } }.try(&.default)
        !!default.try(&.matches?(/datetime|current_(timestamp|date|time)|julianday|unixepoch/i))
      end

      # A table column by the name its table goes by in the statement, since
      # in WHERE a bare name can be ambiguous where ORDER BY found a result
      # column.
      private def qualified(column : ResultColumn) : String?
        table, origin = column.table, column.origin
        return unless table && origin

        name = @aliases.find { |key, value| value.compare(table, case_insensitive: true).zero? && key != table.downcase }.try(&.[0]) || table
        "#{name}.#{origin}"
      end

      # Whether the last term tells rows apart: a rowid, or a column with a
      # unique key of its own.
      private def distinct?(term : Term, where : Location, label : String) : Bool
        column = term.column
        table = column.table.try { |name| @schema.table(name) }
        origin = column.origin
        return true if table && origin && (table.rowid.try(&.name) == origin || table.uniques.any? { |unique| unique.columns == [origin] })

        fail(where, "#{label}: ends with #{column.name}, which does not tell rows apart; end it with a key, such as the table's id")
        false
      end

      # The condition after a cursor: a row value comparison when every term
      # sorts the same way, else one OR branch per term.
      private def condition(terms : Array(Term)) : {String, Array(Int32)}
        if terms.all?(&.descending) || terms.none?(&.descending)
          operator = terms.first.descending ? "<" : ">"
          return {"AND #{terms.first.expression} #{operator} ?", [0]} if terms.size == 1

          left = terms.join(", ", &.expression)
          marks = terms.join(", ") { "?" }
          return {"AND (#{left}) #{operator} (#{marks})", (0...terms.size).to_a}
        end
        indexes = [] of Int32
        branches = terms.map_with_index do |term, index|
          parts = terms.first(index).map_with_index do |before, i|
            indexes << i
            "#{before.expression} = ?"
          end
          indexes << index
          parts << "#{term.expression} #{term.descending ? "<" : ">"} ?"
          parts.size == 1 ? parts.first : "(#{parts.join(" AND ")})"
        end
        {"AND (#{branches.join(" OR ")})", indexes}
      end
    end
  end
end
