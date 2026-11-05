module Ameba::Rule::Punch
  # No SQL injection: the SQL argument of every database method is text
  # written in the source, never a value. Accepted, as the first argument of
  # `exec`, `query_all`, `query_one?`, and the other methods named in
  # `Methods`:
  #
  # - a string literal, a constant, or a literal that interpolates only
  #   constants (`"SELECT #{COLUMNS} FROM t"`);
  # - `A + B`, `cond ? A : B`, and parentheses of accepted parts;
  # - a local variable whose every assignment is accepted, including a
  #   `String.build` whose `io` receives only accepted parts through `<<`,
  #   as generated queries assemble their declared clauses;
  # - the block parameter of `CONSTANT.each` when the file defines the
  #   constant as a tuple (`{…}`, which nothing can change) of accepted
  #   parts, or of `CONSTANT.each_line` when it defines it as accepted
  #   text; an array or a hash can be added to anywhere, so its elements
  #   are values;
  # - a parameter of the enclosing method when that method is itself one of
  #   `Methods`, so its own callers are checked (the database layer
  #   forwarding SQL inward).
  #
  # The SQL argument is the first one, or the one named `sql:`. Code in
  # macro bodies (`macro`, `{% begin %}`, `{% if %}`, `{% for %}`) is
  # checked the same way, with every `{{ … }}` taken as a value; a macro
  # body that does not parse as code, or a `{{ … }}` that writes a
  # database call, is reported when it names one of `Methods`.
  #
  # Everything else is reported: interpolating or concatenating a value,
  # `%` formatting, `String.build` with a value, a parameter of a method
  # not in `Methods`, an instance variable. Where SQL text comes from a
  # `.sql` file at run time (migrations, the schema file, the query
  # generator preparing an app's queries), the call says so with
  # `# ameba:disable Punch/SQLText` and a comment why; those lines are the
  # complete list of exceptions.
  #
  # Calls on a module or type are checked as calls on a value
  # (`Helper.exec(db, sql)` is a forwarder), except `Process` and the C
  # bindings (`LibSQLite3.prepare_v2`), which Punch/DriverTypes confines
  # to the driver. `Database::Driver::Connection#shape`, which prepares a
  # statement without running it for the query generator, is not checked.
  # Specs (`*_spec.cr` under a `spec/` directory) are not checked: they
  # run against throwaway databases, and their helpers take table names
  # (`count(db, "items")`); spec support files are.
  #
  # ```
  # Punch/SQLText:
  #   Enabled: true
  # ```
  class SQLText < Base
    properties do
      since_version "1.7.0"
      description "Reports SQL text built from values"
      methods %w[exec exec_script query query_all query_one? query_each scalar_text
        select_all select_first prepared fetch_or_build_prepared_statement]
    end

    MSG         = "SQL text from a value: pass a literal or a constant, or build the statement from constants only, and bind every value as a parameter (lib/punch/docs/queries.md#sql-text-is-never-built-from-values)"
    MSG_FORWARD = "`%s` passes SQL from its caller to `%s`: name it in Punch/SQLText's methods so its callers are checked, or take a constant (lib/punch/docs/queries.md#sql-text-is-never-built-from-values)"
    MSG_MACRO   = "A database call in macro code this rule cannot read: write it outside the macro, with SQL text from the source (lib/punch/docs/queries.md#sql-text-is-never-built-from-values)"

    def test(source : Source)
      return if spec?(source.path)

      visitor = Finder.new(methods, source.ast, source.ast, source.path)
      source.ast.accept(visitor)
      visitor.issues.each { |node, message| issue_for node, message }
    end

    private def spec?(path : String) : Bool
      path.ends_with?("_spec.cr") && (path.starts_with?("spec/") || path.includes?("/spec/"))
    end

    private class Finder < Crystal::Visitor
      getter issues = [] of {Crystal::ASTNode, String}

      @defs = [] of Crystal::Def
      # Calls with a block around the current node, innermost last.
      @blocks = [] of {Crystal::Call, Crystal::Block}

      # *root* is the code searched for assignments: the file, or a macro
      # body read as code; *file* is the whole file, where constants are.
      def initialize(@methods : Array(String), @root : Crystal::ASTNode, @file : Crystal::ASTNode, @path : String)
      end

      def visit(node : Crystal::Macro | Crystal::MacroIf | Crystal::MacroFor | Crystal::MacroVerbatim)
        if code = MacroCode.parse(node, @path)
          inner = Finder.new(@methods, code, @file, @path)
          code.accept(inner)
          issues.concat(inner.issues)
        elsif names_method?(MacroCode.render(node))
          issues << {node, MSG_MACRO}
        end
        MacroCode.expressions(node).each { |expression| issues << {expression, MSG_MACRO} if names_method?(expression.exp.to_s) }
        false
      end

      def visit(node : Crystal::Def)
        @defs << node
        true
      end

      def end_visit(node : Crystal::Def)
        @defs.pop
      end

      def visit(node : Crystal::Call)
        node.block.try { |block| @blocks << {node, block} }
        check(node) if sql_call?(node)
        true
      end

      def end_visit(node : Crystal::Call)
        @blocks.pop if node.block
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def sql_call?(call : Crystal::Call) : Bool
        @methods.includes?(call.name) && !sql_argument(call).nil? && !outside_process?(call.obj)
      end

      # The SQL argument: the first, or the one named `sql:`.
      private def sql_argument(call : Crystal::Call) : Crystal::ASTNode?
        call.args.first? || call.named_args.try(&.find(&.name.==("sql")).try(&.value))
      end

      # `Process` and the C bindings, whose `exec` and `prepare` are not
      # Punch's database methods.
      private def outside_process?(receiver : Crystal::ASTNode?) : Bool
        receiver = receiver.name if receiver.is_a?(Crystal::Generic)
        receiver.is_a?(Crystal::Path) && (receiver.names.first == "Process" || receiver.names.any?(&.starts_with?("Lib")))
      end

      # Whether *text* calls one of the checked methods.
      private def names_method?(text : String) : Bool
        @methods.any? { |name| text.matches?(/\.#{Regex.escape(name)}(?![\w?!])/) }
      end

      private def check(call : Crystal::Call) : Nil
        sql = sql_argument(call) || return
        if (name = local_name(sql)) && (forwarder = forwarding_def(name)) && !@methods.includes?(forwarder.name)
          issues << {sql, MSG_FORWARD % {forwarder.name, call.name}}
        elsif !accepted?(sql, 0)
          issues << {sql, MSG}
        end
      end

      # Whether *node* is SQL text written in the source.
      private def accepted?(node : Crystal::ASTNode, depth : Int32) : Bool
        return false if depth > 8 || MacroCode.value?(node)

        case node
        when Crystal::StringLiteral, Crystal::Path
          true
        when Crystal::StringInterpolation
          node.expressions.all? { |part| text?(part) }
        when Crystal::Expressions
          node.expressions.size == 1 && accepted?(node.expressions.first, depth + 1)
        when Crystal::If
          accepted?(node.then, depth + 1) && accepted?(node.else, depth + 1)
        when Crystal::Call
          accepted_call?(node, depth)
        when Crystal::Var
          local_accepted?(node.name, depth)
        else
          false
        end
      end

      # A part of an interpolation that is text from the source.
      private def text?(part : Crystal::ASTNode) : Bool
        part.is_a?(Crystal::StringLiteral) || (part.is_a?(Crystal::Path) && !MacroCode.value?(part))
      end

      private def accepted_call?(call : Crystal::Call, depth : Int32) : Bool
        left = call.obj
        if call.name == "+" && left && call.args.size == 1
          accepted?(left, depth + 1) && accepted?(call.args.first, depth + 1)
        elsif block = build_block(call)
          built_from_constants?(block)
        elsif name = local_name(call)
          local_accepted?(name, depth)
        else
          false
        end
      end

      # A name that may be a local variable, a block parameter, or a
      # method parameter.
      private def local_name(node : Crystal::ASTNode) : String?
        case node
        when Crystal::Var
          node.name
        when Crystal::Call
          node.name if node.obj.nil? && node.args.empty? && node.named_args.nil? && node.block.nil?
        end
      end

      private def local_accepted?(name : String, depth : Int32) : Bool
        # A block parameter shadows the rest.
        @blocks.reverse_each do |call, block|
          next unless block.args.any?(&.name.==(name))

          receiver = call.obj
          return call.name.in?("each", "each_line") && receiver.is_a?(Crystal::Path) && constant_accepted?(receiver, call.name == "each_line", depth)
        end
        if forwarder = forwarding_def(name)
          return @methods.includes?(forwarder.name) && sql_parameter?(forwarder, name)
        end

        # Outside a method (a spec's `it` block), every assignment in the
        # file counts.
        values = Assignments.new(name)
        (@defs.last?.try(&.body) || @root).accept(values)
        !values.unknown? && !values.values.empty? && values.values.all? { |value| accepted?(value, depth + 1) }
      end

      # Whether the file defines *constant* as a tuple of accepted parts
      # (*lines*: as accepted text), every time it defines a constant of
      # that name.
      private def constant_accepted?(constant : Crystal::Path, lines : Bool, depth : Int32) : Bool
        definitions = Constants.new(constant.names.last)
        @file.accept(definitions)
        !definitions.values.empty? && definitions.values.all? do |value|
          lines ? accepted?(value, depth + 1) : immutable?(value, depth)
        end
      end

      # A tuple whose every element is accepted text or a plain literal,
      # nested tuples included, or the sum of such tuples.
      private def immutable?(node : Crystal::ASTNode, depth : Int32) : Bool
        return false if depth > 8

        case node
        when Crystal::TupleLiteral      then node.elements.all? { |element| immutable_part?(element, depth + 1) }
        when Crystal::NamedTupleLiteral then node.entries.all? { |entry| immutable_part?(entry.value, depth + 1) }
        when Crystal::Path              then constant_accepted?(node, false, depth + 1)
        when Crystal::Call
          left = node.obj
          node.name == "+" && !left.nil? && node.args.size == 1 && immutable?(left, depth + 1) && immutable?(node.args.first, depth + 1)
        else
          false
        end
      end

      private def immutable_part?(node : Crystal::ASTNode, depth : Int32) : Bool
        case node
        when Crystal::SymbolLiteral, Crystal::NumberLiteral, Crystal::BoolLiteral, Crystal::NilLiteral
          true
        when Crystal::TupleLiteral, Crystal::NamedTupleLiteral
          immutable?(node, depth)
        else
          accepted?(node, depth)
        end
      end

      # Whether *name* is where *forwarder* takes SQL, as its callers are
      # checked: the first parameter.
      private def sql_parameter?(forwarder : Crystal::Def, name : String) : Bool
        forwarder.args.first?.try(&.name) == name
      end

      # The enclosing method when *name* is one of its parameters.
      private def forwarding_def(name : String) : Crystal::Def?
        return if @blocks.any? { |_, block| block.args.any?(&.name.==(name)) }

        scope = @defs.last? || return
        scope if scope.args.any?(&.name.==(name))
      end

      # The block of `String.build { |io| ... }`.
      private def build_block(call : Crystal::Call) : Crystal::Block?
        receiver = call.obj
        return unless call.name == "build" && receiver.is_a?(Crystal::Path) && receiver.names == ["String"]

        call.block.try { |block| block if block.args.size == 1 }
      end

      # Whether the block's `io` receives constants and literals only, each
      # through `<<`, and is used for nothing else.
      private def built_from_constants?(block : Crystal::Block) : Bool
        appends = Appends.new(block.args.first.name)
        block.body.accept(appends)
        appends.uses == appends.receivers.size && appends.parts.all? { |part| piece?(part) }
      end

      private def piece?(node : Crystal::ASTNode) : Bool
        case node
        when Crystal::CharLiteral
          true
        when Crystal::Expressions
          node.expressions.size == 1 && piece?(node.expressions.first)
        when Crystal::If
          piece?(node.then) && piece?(node.else)
        else
          node.is_a?(Crystal::StringLiteral) || (node.is_a?(Crystal::Path) && !MacroCode.value?(node)) ||
            (node.is_a?(Crystal::StringInterpolation) && accepted?(node, 0))
        end
      end
    end

    # Every value assigned to a constant named *name*, in any namespace of
    # the file.
    private class Constants < Crystal::Visitor
      getter values = [] of Crystal::ASTNode

      def initialize(@name : String)
      end

      def visit(node : Crystal::Assign)
        target = node.target
        values << node.value if target.is_a?(Crystal::Path) && target.names.last == @name
        false
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end

    # Every value assigned to the local *name*; unknown when a multiple
    # assignment or `out` sets it.
    private class Assignments < Crystal::Visitor
      getter values = [] of Crystal::ASTNode
      getter? unknown = false

      def initialize(@name : String)
      end

      def visit(node : Crystal::Assign)
        target = node.target
        values << node.value if target.is_a?(Crystal::Var) && target.name == @name
        true
      end

      def visit(node : Crystal::OpAssign)
        target = node.target
        values << node.value if target.is_a?(Crystal::Var) && target.name == @name
        true
      end

      def visit(node : Crystal::MultiAssign)
        @unknown = true if node.targets.any? { |target| target.is_a?(Crystal::Var) && target.name == @name }
        true
      end

      def visit(node : Crystal::Out)
        exp = node.exp
        @unknown = true if exp.is_a?(Crystal::Var) && exp.name == @name
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end

    # The parts appended to *io* with `<<`, and how often *io* appears at
    # all: a use that is not the start of a `<<` chain is something else.
    private class Appends < Crystal::Visitor
      getter parts = [] of Crystal::ASTNode
      getter receivers = Set(UInt64).new
      getter uses = 0

      def initialize(@io : String)
      end

      def visit(node : Crystal::Call)
        if node.name == "<<" && node.args.size == 1 && (start = chain_start(node))
          parts << node.args.first
          receivers << start.object_id
        end
        @uses += 1 if node.obj.nil? && node.name == @io && node.args.empty?
        true
      end

      def visit(node : Crystal::Var)
        @uses += 1 if node.name == @io
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end

      private def chain_start(call : Crystal::Call) : Crystal::ASTNode?
        receiver = call.obj
        while receiver.is_a?(Crystal::Call) && receiver.name == "<<"
          receiver = receiver.obj
        end
        receiver if receiver.is_a?(Crystal::Var) && receiver.name == @io
      end
    end
  end
end
