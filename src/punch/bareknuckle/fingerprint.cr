module Punch::Bareknuckle
  # What a Crystal file declares, from the parser alone (no typing), at two
  # depths, to tell which edits a warm compiler could take without
  # re-expanding Punch's whole-program macros:
  #
  # - `skeleton`: the file with every method body dropped, signatures kept.
  #   Equal skeletons mean only bodies changed: the fast path.
  # - `outline`: the skeleton without its methods. Equal outlines mean only
  #   methods were added, removed, or changed their signature.
  #
  # Comments and layout never count: both are printed from the syntax
  # tree, without blank lines.
  #
  # One kind of body counts as a declaration: a method without arguments
  # whose body is one instance variable (`def email; @email; end`), since
  # `Punch::Input` builds its field enum from such getters
  # (`src/punch/input.cr`, `PunchField`). It stays whole in both.
  struct Fingerprint
    getter skeleton : String
    getter outline : String

    def initialize(@skeleton : String, @outline : String)
    end

    # The fingerprint of *source*, or `nil` when it does not parse. Without
    # *strings*, every string literal reads as empty: for a file whose
    # strings only the running app reads (`translations.gen.cr`, whose
    # texts are the value of `CATALOG`), so a changed text is `Data`.
    def self.of(source : String, strings : Bool = true) : Fingerprint?
      skeleton = Crystal::Parser.parse(source).transform(Bodies.new)
      outline = Crystal::Parser.parse(source).transform(Methods.new)
      unless strings
        skeleton = skeleton.transform(Strings.new)
        outline = outline.transform(Strings.new)
      end
      new(print(skeleton), print(outline))
    rescue Crystal::SyntaxException
      nil
    end

    # How *before* became *after*: `Body` when only method bodies differ,
    # `Signature` when only methods were added, removed, or retyped, and
    # `Structure` otherwise, including a file that does not parse.
    #
    # With *data*, a change of string literals alone is `Data`
    # (`of(strings: false)`).
    def self.change(before : String, after : String, data : Bool = false) : Change
      old = of(before) || return Change::Structure
      new = of(after) || return Change::Structure
      return Change::Body if old.skeleton == new.skeleton
      return Change::Signature if old.outline == new.outline
      return Change::Structure unless data

      of(before, strings: false).try(&.skeleton) == of(after, strings: false).try(&.skeleton) ? Change::Data : Change::Structure
    end

    # A method of a file as the parser sees it: the namespace it is declared
    # in, its name, the line it starts on, and the lines of the calls
    # around it (a macro call such as `record … do` that pastes it).
    record Method, owner : String, name : String, line : Int32, anchors : Array(Int32) do
      def to_s(io : IO) : Nil
        io << owner << (owner.empty? ? "" : "#") << name
      end
    end

    # What changed between *before* and *after*, method by method:
    # `changed`, the methods of *before* whose body or signature differ or
    # that are gone; `added`, the names of methods only *after* has; and
    # `outside`, whether anything outside the methods differs (a constant,
    # top-level code). `nil` when either does not parse.
    record MethodChanges, changed : Array(Method), added : Array(String), outside : Bool

    def self.methods(before : String, after : String) : MethodChanges?
      old = Declared.collect(Crystal::Parser.parse(before))
      new = Declared.collect(Crystal::Parser.parse(after))
      changed = old.compact_map { |key, (method, body)| method if new[key]?.try(&.[1]) != body }
      added = new.compact_map { |key, (method, _)| method.name unless old.has_key?(key) }
      outside = Crystal::Parser.parse(before).transform(Methods.new).to_s != Crystal::Parser.parse(after).transform(Methods.new).to_s
      MethodChanges.new(changed, added, outside)
    rescue Crystal::SyntaxException
      nil
    end

    # The methods of a file by their declaration (namespace, signature, and
    # how many with the same declaration come before), each with its body as
    # printed.
    private class Declared < Crystal::Visitor
      getter methods = {} of String => {Method, String}
      @namespace = [] of String
      @anchors = [] of Int32
      @seen = Hash(String, Int32).new(0)

      def self.collect(node : Crystal::ASTNode) : Hash(String, {Method, String})
        visitor = new
        node.accept(visitor)
        visitor.methods
      end

      def visit(node : Crystal::ClassDef | Crystal::ModuleDef) : Bool
        @namespace << node.name.to_s
        true
      end

      def end_visit(node : Crystal::ClassDef | Crystal::ModuleDef) : Nil
        @namespace.pop
      end

      def visit(node : Crystal::Call) : Bool
        @anchors << (node.location.try(&.line_number) || 0)
        true
      end

      def end_visit(node : Crystal::Call) : Nil
        @anchors.pop
      end

      def visit(node : Crystal::Def) : Bool
        owner = @namespace.join("::")
        header = node.clone
        header.body = Crystal::Nop.new
        declaration = "#{owner}\0#{header}"
        key = "#{declaration}\0#{@seen[declaration]}"
        @seen[declaration] += 1
        name = node.receiver ? "#{node.receiver}.#{node.name}" : node.name
        @methods[key] = {Method.new(owner, name, node.location.try(&.line_number) || 0, @anchors.dup), node.body.to_s}
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end

    # The printer keeps the blank lines between expressions, which are
    # layout.
    private def self.print(node : Crystal::ASTNode) : String
      node.to_s.lines.reject(&.blank?).join('\n')
    end

    def self.declaration?(node : Crystal::Def) : Bool
      node.args.empty? && node.body.is_a?(Crystal::InstanceVar)
    end

    # Drops every method body but a getter's (`declaration?`).
    private class Bodies < Crystal::Transformer
      def transform(node : Crystal::Def) : Crystal::ASTNode
        node.body = Crystal::Nop.new unless Fingerprint.declaration?(node)
        node
      end
    end

    # Empties every string literal.
    private class Strings < Crystal::Transformer
      def transform(node : Crystal::StringLiteral) : Crystal::ASTNode
        Crystal::StringLiteral.new("")
      end
    end

    # Drops every method but a getter (`declaration?`).
    private class Methods < Crystal::Transformer
      def transform(node : Crystal::Def) : Crystal::ASTNode
        Fingerprint.declaration?(node) ? node : Crystal::Nop.new
      end
    end
  end

  # How a file changed between two builds, from the cheapest edit for a
  # warm compiler to the most expensive.
  enum Change
    # The contents are the same (the file was only saved again).
    None
    # Only method bodies changed.
    Body
    # Only string literals changed, in a file whose strings only the running
    # app reads: no type and no macro sees them; the program's
    # initialization (`_main`) holds them.
    Data
    # Methods were added or removed, or their parameters or return types
    # changed; nothing else.
    Signature
    # Anything else in a Crystal file: a type, an instance variable, an
    # annotation, an alias, a constant, a macro call, a require.
    Structure
    # A file that is new.
    Added
    # A file that is gone.
    Removed
    # A file that is not Crystal and changed.
    Content
  end
end
