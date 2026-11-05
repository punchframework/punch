module Ameba::Rule::Punch
  # :nodoc:
  # The code inside a macro, which Ameba sees only as text: `macro`
  # definitions, `{% begin %}`, `{% if %}`, and `{% for %}` bodies. Rules
  # that must not be bypassed by wrapping code in a macro (Punch/SQLText,
  # Punch/TrustedHTML) parse it again and check it as ordinary code.
  module MacroCode
    # What a `{{ … }}` becomes: a call, so a rule never takes it for
    # text written in the source; where a call cannot stand (`case … in
    # {{ type }}`), a constant that rules treat as a value (`value?`).
    PLACEHOLDER = "__punch_macro_value__"
    CONSTANT    = "PUNCH_MACRO_VALUE"

    # The code in *node*, each `{{ … }}` replaced by a placeholder, both
    # branches of an `{% if %}` one after the other, on the lines it has in
    # the file named *filename*. Nil when that text does not parse.
    def self.parse(node : Crystal::ASTNode, filename : String) : Crystal::ASTNode?
      {PLACEHOLDER, CONSTANT}.each do |placeholder|
        parser = Crystal::Parser.new(render(node, placeholder))
        parser.filename = filename
        return parser.parse
      rescue Crystal::SyntaxException
        next
      end
    end

    # Whether *node* is the placeholder of a `{{ … }}`.
    def self.value?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Path) && node.names == [CONSTANT]
    end

    # The text *node* holds, as `parse` reads it.
    def self.render(node : Crystal::ASTNode, placeholder : String = PLACEHOLDER) : String
      renderer = Renderer.new(placeholder)
      renderer.add(node)
      renderer.to_s
    end

    # The `{{ … }}` expressions in *node*, outside the literal text.
    def self.expressions(node : Crystal::ASTNode) : Array(Crystal::MacroExpression)
      found = [] of Crystal::MacroExpression
      collect(node, found)
      found
    end

    private def self.collect(node : Crystal::ASTNode, found : Array(Crystal::MacroExpression)) : Nil
      case node
      when Crystal::MacroExpression then found << node if node.output?
      when Crystal::Macro           then collect(node.body, found)
      when Crystal::MacroIf
        collect(node.then, found)
        collect(node.else, found)
      when Crystal::MacroFor      then collect(node.body, found)
      when Crystal::MacroVerbatim then collect(node.exp, found)
      when Crystal::Expressions   then node.expressions.each { |child| collect(child, found) }
      end
    end

    private class Renderer
      @io = IO::Memory.new
      @started = false

      def initialize(@placeholder : String)
      end

      def add(node : Crystal::ASTNode) : Nil
        case node
        when Crystal::MacroLiteral
          start(node)
          @io << node.value
        when Crystal::MacroExpression
          @io << @placeholder if node.output?
        when Crystal::MacroVar
          # `%name`: a variable of its own.
          @io << "__punch_macro_" << node.name
        when Crystal::Macro then add(node.body)
        when Crystal::MacroIf
          add(node.then)
          add(node.else)
        when Crystal::MacroFor      then add(node.body)
        when Crystal::MacroVerbatim then add(node.exp)
        when Crystal::Expressions   then node.expressions.each { |child| add(child) }
        end
      end

      def to_s : String
        @io.to_s
      end

      # Starts the text on the line of the first literal, so parsed nodes
      # carry the file's line numbers; later lines follow from the
      # literals' own line breaks.
      private def start(literal : Crystal::MacroLiteral) : Nil
        return if @started

        @started = true
        literal.location.try { |location| @io << "\n" * (location.line_number - 1) }
      end
    end
  end
end
