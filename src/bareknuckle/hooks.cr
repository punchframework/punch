require "digest/sha256"

# Bareknuckle's hooks into the compiler, by reopening its classes (no
# fork): `require_file` is the compiler's own (Crystal 1.22) with one line
# changed, marked; the macro methods record what they read, then run the
# compiler's own (`previous_def`). Another Crystal version may need other
# copies, which is why `bareknuckle` only runs for the release it was
# built from (`Bareknuckle::CRYSTAL`).
module Crystal
  class SemanticVisitor
    private def require_file(node : Require, filename : String)
      # bareknuckle: the app's files come from the round's sources.
      parser = @program.new_parser(Bareknuckle::Sources.read(filename))
      parser.filename = filename
      parser.wants_doc = @program.wants_doc?
      begin
        parsed_nodes = parser.parse
        parsed_nodes = @program.normalize(parsed_nodes, inside_exp: inside_exp?)
        # We must type the node immediately, in case a file requires another
        # *before* one of the files in `filenames`
        parsed_nodes.accept self
      rescue ex : CodeError
        node.raise "while requiring \"#{node.string}\"", ex
      rescue ex
        raise Error.new "while requiring \"#{node.string}\"", ex
      end

      FileNode.new(parsed_nodes, filename)
    end
  end

  class LLVMId
    # bareknuckle: a digest of every type's IDs, which codegen writes into
    # the code that checks types (`is_a?`, dispatch).
    def digest : String
      ::Digest::SHA256.hexdigest(@ids.map { |type, (min, max)| "#{type} #{min} #{max}" }.sort!.join('\n'))
    end
  end

  class MacroInterpreter
    def interpret_read_file(node, nilable = false)
      # bareknuckle: the file, evaluated once more.
      node.args.first?.try { |arg| arg.accept(self); Bareknuckle::MacroReads.file(@last.to_macro_id) }
      previous_def
    end

    def interpret_file_exists?(node)
      # bareknuckle: the file, evaluated once more.
      node.args.first?.try { |arg| arg.accept(self); Bareknuckle::MacroReads.file(@last.to_macro_id) }
      previous_def
    end

    def interpret_run(node)
      # bareknuckle: the program and its arguments, evaluated once more.
      unless node.args.empty?
        Bareknuckle::MacroReads.command(node.args.map { |arg| arg.accept(self); @last.to_macro_id }.join(" "))
      end
      previous_def
    end

    def interpret_system(node)
      # bareknuckle: the command, evaluated once more.
      Bareknuckle::MacroReads.command(node.args.map { |arg| arg.accept(self); @last.to_macro_id }.join(" "))
      previous_def
    end
  end
end
