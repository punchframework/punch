module Punch::QueryGen
  # Which unique constraints a write can violate, from its tokens and the
  # schema. Only constraints of mapped tables become types; anything else a
  # write violates stays an exception.
  #
  # The answer errs on the side of a constraint that cannot fail: an extra
  # `in` branch costs a line, a missing one would turn a value into an
  # exception.
  module Writes
    # Conflict clauses after which a violation is not a value: `IGNORE`
    # and `REPLACE` never fail, `ROLLBACK` ends the transaction, and `FAIL`
    # keeps what the statement changed before it failed.
    NOT_TYPED = {"IGNORE", "REPLACE", "ROLLBACK", "FAIL"}

    # The table a write targets and the constraints it can violate; `nil`
    # when it is not an `INSERT`, `UPDATE`, or `DELETE` of a mapped table.
    # A `DELETE` can violate only rules of its triggers.
    def self.analyze(tokens : Array(SQL::Token), schema : Schema) : {Schema::Table, Array(Schema::Unique)}?
      start = statement_start(tokens) || return
      return deleting(tokens, start + 1, schema) if tokens[start].keyword?("DELETE")

      writing(tokens, start, schema)
    end

    # An `INSERT` or `UPDATE` whose verb is at *start*.
    private def self.writing(tokens : Array(SQL::Token), start : Int32, schema : Schema) : {Schema::Table, Array(Schema::Unique)}?
      verb = tokens[start]
      i = start + 1
      conflict = verb.keyword?("REPLACE") ? "REPLACE" : nil
      if tokens[i]?.try(&.keyword?("OR"))
        conflict = tokens[i + 1]?.try(&.text.upcase)
        i += 2
      end
      return if conflict.in?(NOT_TYPED)

      i += 1 if tokens[i]?.try(&.keyword?("INTO"))
      i += 2 if tokens[i + 1]?.try(&.punct?(".")) # main.table
      table = tokens[i]?.try { |token| schema.table(token.text) if token.kind.ident? } || return
      return unless table.mod

      uniques = if verb.keyword?("UPDATE")
                  updated(table, assignments(tokens, i + 1, table) || return)
                else
                  insert_statement(tokens, i + 1, table)
                end
      {table, uniques}
    end

    # The constraints an `INSERT` of *provided* columns can violate: those
    # whose every key column gets a value (NULLs never conflict), and an
    # expression key when any column it reads gets one.
    def self.inserted(table : Schema::Table, provided : Set(String)) : Array(Schema::Unique)
      filled = provided.dup
      table.columns.each { |column| filled << column.name if column.generated? || default?(column) }
      table.uniques.select do |unique|
        if unique.trigger?
          unique.fired_by?("INSERT")
        elsif unique.rowid?
          provided.includes?(unique.columns.first)
        elsif unique.columns.empty?
          unique.referenced.any? { |name| filled.includes?(name) }
        else
          unique.columns.all? { |name| filled.includes?(name) }
        end
      end
    end

    # The constraints an `UPDATE` of *set* columns can violate: those
    # reading any of them, the `WHERE` of a partial index included.
    def self.updated(table : Schema::Table, set : Set(String)) : Array(Schema::Unique)
      table.uniques.select do |unique|
        unique.trigger? ? unique.fired_by?("UPDATE", set) : unique.referenced.any? { |name| set.includes?(name) }
      end
    end

    # The rules a `DELETE` of *table*'s rows can violate: its triggers'.
    def self.deleted(table : Schema::Table) : Array(Schema::Unique)
      table.uniques.select(&.fired_by?("DELETE"))
    end

    private def self.deleting(tokens : Array(SQL::Token), i : Int32, schema : Schema) : {Schema::Table, Array(Schema::Unique)}?
      i += 1 if tokens[i]?.try(&.keyword?("FROM"))
      i += 2 if tokens[i + 1]?.try(&.punct?(".")) # main.table
      table = tokens[i]?.try { |token| schema.table(token.text) if token.kind.ident? } || return
      {table, deleted(table)} if table.mod
    end

    private def self.default?(column : Schema::Column) : Bool
      default = column.default || return false
      default.compare("NULL", case_insensitive: true) != 0
    end

    # The index of the statement's verb, after any `WITH` clause.
    private def self.statement_start(tokens : Array(SQL::Token)) : Int32?
      depth = 0
      tokens.each_with_index do |token, i|
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        next unless depth == 0
        return i if token.keyword?("INSERT", "REPLACE", "UPDATE", "DELETE")
        return if token.keyword?("SELECT", "VALUES")
      end
    end

    private def self.insert_statement(tokens : Array(SQL::Token), i : Int32, table : Schema::Table) : Array(Schema::Unique)
      if tokens[i]?.try(&.keyword?("AS"))
        i += 2
      end
      provided = if tokens[i]?.try(&.punct?("("))
                   columns(tokens[i + 1...SQL.matching(tokens, i)], table)
                 elsif tokens[i]?.try(&.keyword?("DEFAULT"))
                   Set(String).new
                 else
                   table.columns.reject(&.generated?).map(&.name).to_set
                 end
      uniques = inserted(table, provided)
      upserts(tokens, i, table, uniques)
    end

    # `ON CONFLICT (target) DO …`: the target is no longer violated, and
    # `DO UPDATE SET` can violate what its columns are in. Without a
    # target, nothing from the insert is.
    private def self.upserts(tokens : Array(SQL::Token), from : Int32, table : Schema::Table, uniques : Array(Schema::Unique)) : Array(Schema::Unique)
      # A conflict target never covers a trigger's rule.
      triggered, result = uniques.partition(&.trigger?)
      added = [] of Schema::Unique
      depth = 0
      (from...tokens.size).each do |i|
        depth += 1 if tokens[i].punct?("(")
        depth -= 1 if tokens[i].punct?(")")
        next unless depth == 0 && tokens[i].keyword?("ON") && tokens[i + 1]?.try(&.keyword?("CONFLICT"))
        j = i + 2
        if tokens[j]?.try(&.punct?("("))
          close = SQL.matching(tokens, j)
          target = columns(tokens[j + 1...close], table)
          result.reject! { |unique| (unique.columns.empty? ? unique.referenced : unique.columns).to_set == target }
          j = close + 1
        else
          result.clear
        end
        while j < tokens.size && !tokens[j].keyword?("DO")
          j += 1
        end
        if tokens[j + 1]?.try(&.keyword?("UPDATE"))
          set = assignments(tokens, j + 2, table) || Set(String).new
          added.concat(updated(table, set))
        end
      end
      (triggered + result + added).uniq
    end

    # The columns an `UPDATE … SET` or `DO UPDATE SET` assigns, from *i*,
    # which is just before `SET`; `nil` if there is no `SET`.
    private def self.assignments(tokens : Array(SQL::Token), i : Int32, table : Schema::Table) : Set(String)?
      depth = 0
      set_at = (i...tokens.size).find do |j|
        depth += 1 if tokens[j].punct?("(")
        depth -= 1 if tokens[j].punct?(")")
        depth == 0 && tokens[j].keyword?("SET")
      end
      set_at ? set_columns(tokens, set_at + 1, table) : nil
    end

    # The assigned columns of a `SET` list starting at *start*: the first
    # name of each assignment, or each name of a `(a, b) = …` list.
    private def self.set_columns(tokens : Array(SQL::Token), start : Int32, table : Schema::Table) : Set(String)
      names = Set(String).new
      depth = 0
      expecting = true # at the start of an assignment
      (start...tokens.size).each do |j|
        token = tokens[j]
        if depth == 0 && token.keyword?("FROM", "WHERE", "RETURNING", "ORDER", "LIMIT", "ON", "DO")
          break
        end
        names.concat(assigned(tokens, j, table)) if expecting
        expecting = false
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        expecting = true if depth == 0 && token.punct?(",")
      end
      names
    end

    # The column, or the `(a, b)` columns, an assignment starting at *j* sets.
    private def self.assigned(tokens : Array(SQL::Token), j : Int32, table : Schema::Table) : Set(String)
      token = tokens[j]
      return columns(tokens[j + 1...SQL.matching(tokens, j)], table) if token.punct?("(")

      columns([token], table)
    end

    private def self.columns(tokens : Array(SQL::Token), table : Schema::Table) : Set(String)
      tokens.compact_map { |token| table.column(token.text).try(&.name) if token.kind.ident? }.to_set
    end
  end
end
