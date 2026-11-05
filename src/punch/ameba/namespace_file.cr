module Ameba::Rule::Punch
  # Keeps namespaces and directories one (docs/structure.md):
  #
  # - A file's outermost module is its directory's namespace
  #   (`app/billing/invoices/store.cr` defines types in
  #   `Billing::Invoices`). Directories of a kind (`operations/`, `pages/`,
  #   `jobs/`, `mail/`, `subscribers/`, `components/`) add no namespace;
  #   files directly in `app/` are the app's and not checked.
  # - Every namespace directory has an outline: the file beside it, named
  #   like it (`app/billing/customers.cr` for `app/billing/customers/`),
  #   saying what the concept means and is for, among the others, in plain
  #   words (docs/models.md). A missing one is reported at the first file
  #   of the directory. That file holds the module with its doc comment and
  # at most constants the domain names (a payment term), each documented
  # and a plain value: a number, string, symbol, range, or duration
  # (`14.days`). So it costs nothing to compile and stays a place to read,
  # not a second place for code. No other file puts a doc comment on that
  # module: `crystal docs` keeps the last one it reads, which would
  # replace the outline (separate a file's header comment by a blank
  # line). The placeholder `punch generate` writes into a new outline
  # (`# punch generate: say here …`) is reported until it is replaced.
  #
  # ```
  # Punch/NamespaceFile:
  #   Enabled: true
  # ```
  class NamespaceFile < Base
    properties do
      since_version "1.7.0"
      description "Reports a file whose types are outside its directory's namespace, a namespace directory without its outline file, an outline that is not a documented module holding only documented plain constants, and a doc comment on the module elsewhere"
    end

    MISSING     = "`%s` is a namespace: outline it in `%s`, a documented `module %s` (lib/punch/docs/models.md)"
    OUTSIDE     = "`%s` is outside `%s`, the namespace of this file's directory: a file's outermost module is its directory's; move it to `%s` (lib/punch/docs/structure.md)"
    KINDS       = %w[operations pages jobs mail subscribers components]
    SHAPE       = "`%s` outlines the namespace in `%s/`: it holds only `module %s` with a doc comment, nothing else (lib/punch/docs/models.md)"
    NO_DOC      = "`module %s` is an outline: say what it means and is for in a doc comment above it (lib/punch/docs/models.md)"
    CODE        = "`module %s` is an outline: only constants with a plain value (number, string, symbol, range, `14.days`) belong here; move code into the files under `%s/` (lib/punch/docs/models.md)"
    CONST_DOC   = "`%s` is a constant of an outline: say what it means in a comment above it (lib/punch/docs/models.md)"
    PLACEHOLDER = "`punch generate` left this outline for you to write: say what `%s` means and is for, in plain words, in place of this line (lib/punch/docs/models.md)"
    REOPENED    = "The doc comment of `%s` is its outline in `%s`: this one would replace it in `crystal docs`; leave a blank line below a file's header (lib/punch/docs/models.md)"

    def test(source : Source)
      path = source.path
      return unless app?(path)

      check_placeholder(source)
      check_missing(source, path)
      if namespace?(path.rchop(".cr"))
        check_outline(source, path.rchop(".cr"))
      else
        check_reopenings(source, path) unless path.ends_with?(".gen.cr")
        check_placement(source, path)
      end
    end

    # The directory of the file's namespace: its own, or above a kind
    # directory.
    private def home(path : String) : String
      directory = File.dirname(path)
      KINDS.includes?(File.basename(directory)) ? File.dirname(directory) : directory
    end

    # A directory under `app/` that is a namespace: not `app/` itself, not a
    # kind directory, and holding Crystal or SQL files.
    private def namespace?(directory : String) : Bool
      return false if KINDS.includes?(File.basename(directory)) || File.basename(directory) == "app" || !app?(directory + "/")

      Dir.exists?(directory) && !Dir.glob(["#{directory}/**/*.cr", "#{directory}/**/*.sql"]).empty?
    end

    # Reports a namespace without its outline once, at its first file.
    private def check_missing(source : Source, path : String) : Nil
      directory = home(path)
      return if !namespace?(directory) || File.exists?("#{directory}.cr")

      own = Dir.glob("#{directory}/*.cr").sort!
      own = Dir.glob(KINDS.map { |kind| "#{directory}/#{kind}/*.cr" }).sort! if own.empty?
      return unless own.first? == path || own.first?.try { |first| File.expand_path(first) == File.expand_path(path) }

      name = module_name(directory)
      issue_for({1, 1}, MISSING % {name, "#{directory}.cr", name})
    end

    # The doc comment `punch generate` writes into a new outline, until it
    # is replaced.
    private def check_placeholder(source : Source) : Nil
      source.lines.each_with_index do |line, index|
        next unless line.starts_with?("# punch generate:")
        name = source.lines[index..].find(&.starts_with?("module ")).try(&.lchop("module ").strip) || "this namespace"
        issue_for({index + 1, 1}, PLACEHOLDER % name)
      end
    end

    # Types defined outside the namespace of the file's directory.
    private def check_placement(source : Source, path : String) : Nil
      directory = home(path)
      return unless namespace?(directory)

      expected = module_name(directory).split("::")
      root = path.starts_with?("app/") ? "app/" : path[0, path.index!("/app/") + 5]
      visit_placement(source, source.ast, [] of String, expected, root)
    end

    private def visit_placement(source : Source, node : Crystal::ASTNode, prefix : Array(String), expected : Array(String), root : String) : Nil
      case node
      when Crystal::Expressions
        node.expressions.each { |child| visit_placement(source, child, prefix, expected, root) }
      when Crystal::ModuleDef, Crystal::ClassDef, Crystal::EnumDef, Crystal::Alias
        full = prefix + node.name.names
        return if full[0, expected.size]? == expected

        if full.size < expected.size && expected[0, full.size] == full && !node.is_a?(Crystal::EnumDef) && !node.is_a?(Crystal::Alias)
          body = node.is_a?(Crystal::ModuleDef) ? node.body : node.as(Crystal::ClassDef).body
          visit_placement(source, body, full, expected, root)
          return
        end
        target = root + full[0...-1].join('/', &.underscore)
        issue_for(node, OUTSIDE % {full.join("::"), expected.join("::"), target.rchop('/') + "/"})
      end
    end

    # A doc comment on a namespace's module in a file other than its outline.
    private def check_reopenings(source : Source, path : String) : Nil
      root = path.starts_with?("app/") ? "app/" : path[0, path.index!("/app/") + 5]

      modules = case node = source.ast
                when Crystal::ModuleDef   then [node]
                when Crystal::Expressions then node.expressions.select(Crystal::ModuleDef)
                else                           [] of Crystal::ModuleDef
                end
      modules.each do |mod|
        names = mod.name.names
        directory = root + names.join('/', &.underscore)
        next unless namespace?(directory)
        line = mod.location.try(&.line_number) || 1
        next unless line >= 2 && source.lines[line - 2].lstrip.starts_with?('#')
        issue_for(mod, REOPENED % {names.join("::"), "#{directory}.cr"})
      end
    end

    private def check_outline(source : Source, directory : String) : Nil
      name = module_name(directory)
      node = source.ast
      unless node.is_a?(Crystal::ModuleDef) && node.name.names.join("::") == name
        issue_for({1, 1}, SHAPE % {source.path, directory, name})
        return
      end
      issue_for(node, NO_DOC % name) unless documented?(source, node)
      body = node.body
      members = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
      members.each do |member|
        next if member.is_a?(Crystal::Nop)
        if member.is_a?(Crystal::Assign) && member.target.is_a?(Crystal::Path) && plain?(member.value)
          issue_for(member, CONST_DOC % member.target) unless documented?(source, member)
        else
          issue_for(member, CODE % {name, directory})
        end
      end
    end

    # A literal, a range of literals, or a duration such as `14.days`.
    private def plain?(value : Crystal::ASTNode) : Bool
      case value
      when Crystal::NumberLiteral, Crystal::StringLiteral, Crystal::SymbolLiteral, Crystal::BoolLiteral
        true
      when Crystal::RangeLiteral
        plain?(value.from) && plain?(value.to)
      when Crystal::Call
        value.obj.is_a?(Crystal::NumberLiteral) && value.args.empty? && value.block.nil? && value.named_args.nil?
      else
        false
      end
    end

    private def documented?(source : Source, node : Crystal::ASTNode) : Bool
      line = node.location.try(&.line_number) || 1
      line >= 2 && source.lines[line - 2].lstrip.starts_with?('#')
    end

    private def app?(path : String) : Bool
      path.starts_with?("app/") || path.includes?("/app/")
    end

    # `Billing::Customers` for `…/app/billing/customers`.
    private def module_name(directory : String) : String
      relative = directory.includes?("/app/") ? directory.split("/app/", 2).last : directory.lchop("app/")
      relative.split('/').join("::", &.camelcase)
    end
  end
end
