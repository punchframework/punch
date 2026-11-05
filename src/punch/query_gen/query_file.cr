module Punch::QueryGen
  # What a named query returns, from its header (sqlc's annotation style).
  enum Kind
    One      # the first row, or nil
    Many     # every row
    Exec     # nothing
    ExecRows # the number of rows changed
    Page     # one page of rows in a fixed order, and a cursor to the next
  end

  # A declared clause inside a statement:
  # `-- when status: AND i.status = :status` narrows the query when its
  # filter field is set, `-- when state = draft: AND …` when an enum field
  # holds that member, `-- order newest: ORDER BY …` is one choice of the
  # `Order` enum. The line stays an SQL comment, so the file runs as the
  # unfiltered query.
  class Clause
    enum Kind
      When
      Order
    end

    getter kind : Kind
    getter key : String
    # The enum member a `when` clause stands for (`draft` in `-- when
    # state = draft:`), `nil` for a clause of its own field.
    getter member : String?
    getter location : Location
    # The clause's SQL, as written after the colon.
    getter sql : String
    # The line within the query's statement, 0 for its first.
    getter line : Int32
    # The characters before the SQL on its line (`-- when status:` and the
    # spaces after it), which `Query#assemble` replaces with spaces so that
    # SQLite's error offsets still point at the file's column.
    getter prefix : Int32

    # Whether this is an order read backwards (`direction: :desc`).
    getter? reversed : Bool

    def initialize(@kind, @key, @location, @sql, @line, @prefix, @reversed = false, @member = nil)
    end

    # The order read backwards, at the same place in the statement.
    def reversed : Clause
      Clause.new(kind, key, location, SQL.reverse_order(sql), line, prefix, true)
    end

    # `status = draft` for a member's clause, else the key.
    def label : String
      member.try { |name| "#{key} = #{name}" } || key
    end
  end

  # One named query from a `.sql` file:
  #
  # ```sql
  # -- name: ForCustomer :many
  # -- Invoices of one customer, newest first.
  # -- column total: Int64
  # -- include Billing::Invoice::Due
  # SELECT ...
  # ```
  class Query
    getter name : String
    getter kind : Kind
    getter location : Location
    # The statement as written, without the trailing semicolon.
    getter sql : String
    # The file line of the statement's first line.
    getter sql_line : Int32
    # Comment lines of the header that are not annotations.
    getter doc : Array(String)
    # `"column x"` or `"param x"` to the declared type.
    getter annotations : Hash(String, Type)
    # `-- param state: Ledger::InvoiceState`: the enum of a filter field
    # whose clauses stand for its members, with where it is named.
    getter enums : Hash(String, {String, Location})
    # Behaviour modules the query's `Row` includes, with where each is
    # named.
    getter includes : Array({String, Location})
    # Declared clauses, in the order written.
    getter clauses : Array(Clause)
    # `-- scan: reason` and `-- sort: reason`: plan findings the author
    # accepts (`punch db:explain`), by kind, with the reason and where it is.
    getter accepted : Hash(String, {String, Location})

    def initialize(@name, @kind, @location, @sql, @sql_line, @doc, @annotations, @includes, @clauses = [] of Clause,
                   @enums = {} of String => {String, Location}, @accepted = {} of String => {String, Location})
    end

    def whens : Array(Clause)
      clauses.select(&.kind.when?)
    end

    def orders : Array(Clause)
      clauses.select(&.kind.order?)
    end

    # The statement with the clauses in *on* switched on: their lines become
    # SQL at the same columns, every other clause stays a comment.
    def assemble(on : Enumerable(Clause)) : String
      lines = sql.lines(chomp: false)
      on.each do |clause|
        newline = lines[clause.line].ends_with?('\n') ? "\n" : ""
        lines[clause.line] = " " * clause.prefix + clause.sql + newline
      end
      lines.join
    end

    # Every `when` clause and the first order: the statement the generator
    # types.
    def assemble_full : String
      assemble(whens + orders.first(1))
    end

    def method_name : String
      QueryGen.underscore(name)
    end

    # The location of character *offset* in `sql`.
    def location_at(offset : Int32) : Location
      before = sql[0, offset]
      line = sql_line + before.count('\n')
      column = offset - (before.rindex('\n').try(&.+(1)) || 0) + 1
      Location.new(location.file, line, column)
    end
  end

  # Reads every named query of one file.
  module QueryFile
    NAME       = /\A--\s*name:\s*(\S+)\s+:(\w+)\s*\z/
    ANNOTATION = /\A--\s*(column|param)\s+(\w+)\s*:\s*(.+?)\s*\z/
    INCLUDE    = /\A--\s*include\s+(\S+)\s*\z/
    ACCEPT     = /\A--\s*(scan|sort):\s*(.*?)\s*\z/
    CLAUSE     = /\A(\s*--\s*(when|order)\s+(\S+?)(?:\s*=\s*(\S+?))?\s*:\s*)(.*?)\s*\z/
    ANNOTATE   = "annotate with Int64, Float64, String, Bytes, Bool, or Time, nilable with `?`. Domain types come from columns.cr."
    CONSTANT   = /\A(::)?[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

    def self.parse(source : String, file : String, errors : Array(Error)) : Array(Query)
      queries = [] of Query
      lines = source.lines
      starts = [] of Int32
      lines.each_with_index { |line, index| starts << index if line.lstrip.starts_with?("--") && line.strip.matches?(/\A--\s*name:/) }
      first_sql = lines.each_with_index.find { |line, _| !line.blank? && !line.lstrip.starts_with?("--") }
      if first_sql && (starts.empty? || first_sql[1] < starts.first)
        errors << Error.new(Location.new(file, first_sql[1] + 1, 1), "SQL outside a named query; start each query with `-- name: Name :many` (or :one, :exec, :execrows)")
      end
      starts.each_with_index do |start, index|
        stop = starts[index + 1]? || lines.size
        query = parse_query(lines, start, stop, file, errors)
        queries << query if query
      end
      seen = {} of String => Query
      queries.each do |query|
        if other = seen[query.name]?
          errors << Error.new(query.location, "query #{query.name} is defined twice; the first is at line #{other.location.line}")
        end
        seen[query.name] = query
      end
      queries
    end

    private def self.parse_query(lines : Array(String), start : Int32, stop : Int32, file : String, errors : Array(Error)) : Query?
      location = Location.new(file, start + 1, 1)
      name, kind = header(lines[start], location, errors) || return
      doc = [] of String
      annotations = {} of String => Type
      enums = {} of String => {String, Location}
      includes = [] of {String, Location}
      accepted = {} of String => {String, Location}
      index = start + 1
      while index < stop && (lines[index].blank? || lines[index].lstrip.starts_with?("--"))
        line, at = lines[index].strip, Location.new(file, index + 1, 1)
        if match = line.match(ACCEPT)
          accept(match, name, at, accepted, errors)
        else
          comment(line, name, at, doc, annotations, enums, includes, errors)
        end
        index += 1
      end
      # The statement ends at its last line of SQL; trailing comments and
      # blank lines belong to no query.
      last = stop - 1
      while last >= index && (lines[last].blank? || lines[last].lstrip.starts_with?("--")) && !lines[last].matches?(CLAUSE)
        last -= 1
      end
      if last < index
        errors << Error.new(location, "query #{name} has no SQL")
        return
      end
      sql = lines[index..last].join('\n').rstrip
      sql = sql.rchop(';').rstrip if sql.ends_with?(';')
      clauses = clauses(lines, index, last, name, file, errors)
      check_enums(clauses, enums, name, errors)
      Query.new(name, kind, location, sql, index + 1, doc, annotations, includes, clauses, enums, accepted)
    end

    # The `-- when` and `-- order` lines of a statement.
    private def self.clauses(lines : Array(String), first : Int32, last : Int32, name : String, file : String, errors : Array(Error)) : Array(Clause)
      clauses = [] of Clause
      (first..last).each do |index|
        match = lines[index].match(CLAUSE) || next
        kind = match[2] == "when" ? Clause::Kind::When : Clause::Kind::Order
        key = match[3]
        member = match[4]?
        sql = match[5]
        location = Location.new(file, index + 1, match[1].size + 1)
        if problem = clause_problem(clauses, kind, key, member, sql)
          label = member ? "#{key} = #{member}" : key
          problem = "#{match[2]} #{label}#{problem}"
        end
        if problem
          errors << Error.new(location, "query #{name}: #{problem}")
          next
        end
        clauses << Clause.new(kind, key, location, sql, index - first, match[1].size, member: member)
      end
      clauses
    end

    # What is wrong with a clause, after its kind and label (`when status`):
    # `nil` when nothing is.
    private def self.clause_problem(clauses : Array(Clause), kind : Clause::Kind, key : String, member : String?, sql : String) : String?
      if problem = name_problem(kind, key, member)
        problem
      elsif sql.empty?
        " has no SQL"
      elsif clauses.any? { |other| other.kind == kind && other.key == key && other.member == member }
        " is declared twice"
      elsif kind.when? && (other = clauses.find { |clause| clause.kind.when? && clause.key == key && clause.member.nil? != member.nil? })
        ": `#{key}` is either one clause with a parameter or one clause per member (`-- when #{key} = draft:`), not both; the other is at line #{other.location.line}"
      elsif sql.ends_with?(';')
        ": the statement's `;` goes after its last line, not in a clause"
      end
    end

    private def self.name_problem(kind : Clause::Kind, key : String, member : String?) : String?
      if !QueryGen.identifier?(key)
        ": name the clause in snake_case, as it becomes #{kind.when? ? "a filter field" : "an order"}"
      elsif member && kind.order?
        ": an order has a name, not a member; write `-- order #{key}:`"
      elsif member && !QueryGen.identifier?(member)
        ": write the member in snake_case, as a query string names it (`draft` for Draft)"
      end
    end

    # Each field whose clauses stand for members names its enum, on
    # consecutive lines, and each enum named belongs to such a field.
    private def self.check_enums(clauses : Array(Clause), enums : Hash(String, {String, Location}), name : String, errors : Array(Error)) : Nil
      clauses.select(&.member).group_by(&.key).each do |key, members|
        lines = members.map(&.line)
        if !enums.has_key?(key)
          errors << Error.new(members.first.location, "query #{name}: when #{members.first.label}: name the enum whose members the clauses stand for in the header, `-- param #{key}: Billing::Invoice::Status`")
        elsif lines.last - lines.first != lines.size - 1
          errors << Error.new(members.first.location, "query #{name}: when #{key}: the clauses of one field's members go on consecutive lines")
        end
      end
      enums.each do |key, (type, location)|
        next if clauses.any? { |clause| clause.key == key && clause.member }
        errors << Error.new(location, "query #{name}: param #{key}: #{ANNOTATE} An enum such as #{type} names a filter field with one clause per member (`-- when #{key} = draft: AND …`)")
      end
    end

    # `-- name: Name :kind`
    private def self.header(line : String, location : Location, errors : Array(Error)) : {String, Kind}?
      match = line.strip.match(NAME)
      name, kind_name = match ? {match[1], match[2]} : {"", ""}
      kind = Kind.parse?(kind_name.camelcase)
      problem = if match.nil?
                  "write the query header as `-- name: Name :kind`"
                elsif !name.matches?(/\A[A-Z][A-Za-z0-9]*\z/)
                  "query name #{name} must be CamelCase, such as ForCustomer"
                elsif kind.nil? || kind_name != QueryGen.underscore(kind.to_s).delete('_')
                  "query #{name}: unknown kind :#{kind_name}; use :one, :many, :page, :exec, or :execrows"
                end
      if problem || kind.nil?
        errors << Error.new(location, problem || "")
        return
      end
      {name, kind}
    end

    # A header comment: an annotation, an include, or a line of
    # documentation.
    # `-- scan: reason`: needs the reason, once per kind.
    private def self.accept(match : Regex::MatchData, name : String, location : Location, accepted : Hash(String, {String, Location}), errors : Array(Error)) : Nil
      kind, reason = match[1], match[2]
      if reason.empty?
        errors << Error.new(location, "query #{name}: #{kind}: say why the #{kind == "scan" ? "full scan" : "sort"} is fine, such as `-- #{kind}: a few rows per customer`")
      elsif other = accepted[kind]?
        errors << Error.new(location, "query #{name}: #{kind} is accepted twice; the first is at line #{other[1].line}")
      else
        accepted[kind] = {reason, location}
      end
    end

    private def self.comment(line : String, name : String, location : Location, doc : Array(String), annotations : Hash(String, Type),
                             enums : Hash(String, {String, Location}), includes : Array({String, Location}), errors : Array(Error)) : Nil
      if line.matches?(CLAUSE)
        errors << Error.new(location, "query #{name}: a clause goes inside the statement, where it applies, not in the header")
      elsif match = line.match(INCLUDE)
        mod = match[1]
        if !CONSTANT.matches?(mod)
          errors << Error.new(location, "query #{name}: include takes a module name, such as Billing::Invoice::Due")
        elsif includes.any?(&.[0].==(mod))
          errors << Error.new(location, "query #{name} includes #{mod} twice")
        else
          includes << {mod, location}
        end
      elsif match = line.match(ANNOTATION)
        if type = QueryGen.annotation_type(match[3])
          annotations["#{match[1]} #{match[2]}"] = type
        elsif match[1] == "param" && CONSTANT.matches?(match[3])
          enums[match[2]] = {match[3], location}
        else
          errors << Error.new(location, "query #{name}: #{match[1]} #{match[2]}: #{ANNOTATE}")
        end
      elsif line.starts_with?("--")
        doc << line.lchop("--").lchop(" ")
      end
    end
  end
end
