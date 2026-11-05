module Bareknuckle
  # Which methods of a file an edit changed, from its text before and
  # after, parsed as the compiler parses it. Only an edit that leaves
  # everything outside methods as it was, in text and in place, can take
  # the fast path; a method counts as changed when its text or its place
  # in the file changed, since debug information records every line and
  # column.
  module Changes
    # *before* and *after*: the method as parsed from the old and the new
    # text, with the new text of the whole file (*content*).
    record Change, path : String, name : String, before : Crystal::Def, after : Crystal::Def, content : String

    # Raises `Warm::Refused` when the edit is more than method bodies.
    def self.of(program : Crystal::Program, path : String, before : String, after : String) : Array(Change)
      return [] of Change if before == after

      old = Shape.of(program, path, before)
      new = Shape.of(program, path, after)
      if old.outside.map(&.to_s) != new.outside.map(&.to_s) || old.headers != new.headers
        raise Warm::Refused.new("#{path}: changed outside methods")
      end
      old.outside.zip(new.outside) do |was, now|
        # No code of their own where they are.
        next if was.is_a?(Crystal::Macro | Crystal::Annotation | Crystal::Require | Crystal::Alias | Crystal::AnnotationDef)
        raise Warm::Refused.new("#{path}: code outside methods moved (line #{was.location.try(&.line_number)})") unless was.location == now.location
      end
      raise Warm::Refused.new("#{path}: methods were added or removed") unless old.defs.size == new.defs.size

      old_lines = before.lines
      new_lines = after.lines
      changes = [] of Change
      old.defs.zip(new.defs) do |was, now|
        raise Warm::Refused.new("#{path}: #{was.name}'s signature changed") unless Changes.signature(was) == Changes.signature(now)
        next if was.location == now.location && was.end_location == now.end_location && Changes.text(old_lines, was) == Changes.text(new_lines, now)

        if Changes.assigned(was) != Changes.assigned(now)
          raise Warm::Refused.new("#{path}: #{was.name} assigns instance, class or global variables differently")
        end
        changes << Change.new(path, was.name, was, now, after)
      end
      changes
    end

    # A method without its body, and what the parser noted about it.
    def self.signature(node : Crystal::Def) : String
      copy = node.clone.as(Crystal::Def)
      copy.body = Crystal::Nop.new
      "#{copy} #{node.calls_super?} #{node.calls_initialize?} #{node.calls_previous_def?} #{node.uses_block_arg?} " \
      "#{node.assigns_special_var?} #{node.block_arity}"
    end

    # The lines a method spans.
    def self.text(lines : Array(String), node : Crystal::Def) : String?
      first = node.location.try(&.line_number) || return
      last = node.end_location.try(&.line_number) || return
      lines[(first - 1)..(last - 1)]?.try(&.join('\n'))
    end

    # What the method assigns to instance, class and global variables:
    # the compiler guesses their types from those assignments before it
    # types any method.
    def self.assigned(node : Crystal::Def) : Array(String)
      visitor = Assigned.new
      node.body.accept(visitor)
      visitor.assignments
    end

    private class Assigned < Crystal::Visitor
      getter assignments = [] of String

      def visit(node : Crystal::Assign) : Bool
        note(node, node.target)
      end

      def visit(node : Crystal::OpAssign) : Bool
        note(node, node.target)
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        note(node, node.var)
      end

      def visit(node : Crystal::UninitializedVar) : Bool
        note(node, node.var)
      end

      private def note(node : Crystal::ASTNode, target : Crystal::ASTNode) : Bool
        @assignments << node.to_s if target.is_a?(Crystal::InstanceVar | Crystal::ClassVar | Crystal::Global)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        @assignments << node.to_s if node.targets.any?(Crystal::InstanceVar | Crystal::ClassVar | Crystal::Global)
        true
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end

    # A file's methods, in order, the code outside them, and the
    # declarations around them (classes, modules, visibility).
    private class Shape < Crystal::Visitor
      getter defs = [] of Crystal::Def
      getter outside = [] of Crystal::ASTNode
      getter headers = [] of String

      def self.of(program : Crystal::Program, path : String, source : String) : Shape
        parser = program.new_parser(source)
        parser.filename = path
        node = begin
          parser.parse
        rescue Crystal::SyntaxException
          raise Warm::Refused.new("#{path}: does not parse")
        end
        shape = new
        node.accept(shape)
        shape
      end

      def visit(node : Crystal::Expressions) : Bool
        true
      end

      def visit(node : Crystal::ClassDef) : Bool
        header = node.clone.as(Crystal::ClassDef)
        header.body = Crystal::Nop.new
        @headers << header.to_s
        true
      end

      def visit(node : Crystal::ModuleDef) : Bool
        header = node.clone.as(Crystal::ModuleDef)
        header.body = Crystal::Nop.new
        @headers << header.to_s
        true
      end

      def visit(node : Crystal::VisibilityModifier) : Bool
        @headers << node.modifier.to_s
        true
      end

      def visit(node : Crystal::Def) : Bool
        @defs << node
        false
      end

      def visit(node : Crystal::Nop) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        @outside << node
        false
      end
    end
  end
end
