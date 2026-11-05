require "compiler/crystal/syntax"
require "./query_gen"

module Punch
  # The generator behind `punch requires:generate`: one file,
  # `app/requires.gen.cr`, that requires every Crystal file under `app/` in
  # the order of its kind, so adding a file needs no require and the order
  # is the same in every app. Not part of `require "punch"`.
  #
  # Every file has a kind, from its name or the directory it is in
  # (`KINDS`); one that fits none is refused, with the kinds. Within a
  # kind, shallower files come first (a slice's `types.cr` before an
  # entity's), then by path.
  module RequiresGen
    alias Error = QueryGen::Error
    alias Location = QueryGen::Location

    DIRECTORY = "app"
    OUTPUT    = "app/requires.gen.cr"

    # What a file is, which decides where it is required.
    enum Kind
      Translations
      Types
      Events
      Outline
      Columns
      Records
      Named
      Setup
      Record
      Queries
      Store
      Shared
      Operations
      Components
      Pages
      Roles

      # Which files are of this kind, for the generated file and the
      # refusal.
      def description : String
        case self
        in Translations then "translations.gen.cr, from punch i18n:generate"
        in Setup        then "setup.cr in app/: every Punch.* declaration and Punch::*.config, after the types it names"
        in Types        then "types.cr: IDs and domain primitives"
        in Events       then "events.cr: the namespace's domain events"
        in Outline      then "outlines: X.cr beside the directory X/"
        in Columns      then "columns.cr and composites.cr: column types and composites"
        in Records      then "records.gen.cr and composites.gen.cr, from punch db:generate"
        in Named        then "files named after the type they hold (invoice.cr holds Invoice)"
        in Record       then "record.cr: behaviour of a generated record"
        in Queries      then "queries.gen.cr, from punch db:generate"
        in Store        then "store.cr"
        in Shared       then "inputs.cr, results.cr, policies.cr"
        in Operations   then "operations/, jobs/, mail/, subscribers/: one file per type"
        in Components   then "components.cr and components/"
        in Pages        then "pages/: one file per page"
        in Roles        then "roles.cr: roles name operations, so they come last"
        end
      end
    end

    FIXED = {
      "translations.gen.cr" => Kind::Translations,
      "types.cr"            => Kind::Types,
      "events.cr"           => Kind::Events,
      "columns.cr"          => Kind::Columns,
      "composites.cr"       => Kind::Columns,
      "records.gen.cr"      => Kind::Records,
      "composites.gen.cr"   => Kind::Records,
      "record.cr"           => Kind::Record,
      "queries.gen.cr"      => Kind::Queries,
      "store.cr"            => Kind::Store,
      "inputs.cr"           => Kind::Shared,
      "results.cr"          => Kind::Shared,
      "policies.cr"         => Kind::Shared,
      "components.cr"       => Kind::Components,
      "roles.cr"            => Kind::Roles,
    }

    DIRECTORIES = {
      "operations"  => Kind::Operations,
      "jobs"        => Kind::Operations,
      "mail"        => Kind::Operations,
      "subscribers" => Kind::Operations,
      "components"  => Kind::Components,
      "pages"       => Kind::Pages,
    }

    record Output, path : String, content : String, files : Int32

    # The require file for the Crystal files under *root*'s `app/`, or
    # raises `QueryGen::Errors` naming each file that fits no kind.
    def self.run(root : String = ".") : Output
      directory = File.join(root, DIRECTORY)
      files = Dir.glob("#{directory}/**/*.cr").map { |path| ::Path[path].relative_to(directory).to_s }
      files.delete(::Path[OUTPUT].relative_to(DIRECTORY).to_s)
      errors = [] of Error
      kinds = files.compact_map do |file|
        kind = kind(file, directory, errors)
        {file, kind} if kind
      end
      raise QueryGen::Errors.new(errors) unless errors.empty?
      sorted = kinds.sort_by { |file, kind| {kind.value, file.count('/'), file} }
      Output.new(File.join(root, OUTPUT), render(sorted), sorted.size)
    end

    def self.kind(file : String, directory : String, errors : Array(Error)) : Kind?
      name = File.basename(file)
      parent = File.basename(File.dirname(file))
      return Kind::Setup if file == "setup.cr"
      return DIRECTORIES[parent] if DIRECTORIES.has_key?(parent) && File.dirname(file) != "."
      if kind = FIXED[name]?
        return kind
      end
      return Kind::Outline if Dir.exists?(File.join(directory, file.rchop(".cr")))

      path = File.join(DIRECTORY, file)
      types = defined_types(File.read(File.join(directory, file)), path, errors) || return
      return Kind::Named if types.any? { |type| QueryGen.underscore(type) == name.rchop(".cr") }

      errors << Error.new(Location.new(path, 1), unknown(name, types))
      nil
    end

    # The message for a file that fits no kind.
    def self.unknown(name : String, types : Array(String)) : String
      String.build do |io|
        io << "no file kind fits " << name << ": "
        if types.empty?
          io << "it defines no type; "
        else
          io << "it holds " << types.first(3).join(", ") << " but is not named after one of them (" << QueryGen.underscore(types.last) << ".cr); "
        end
        io << "name it after the type it holds, or make it a file of another kind"
      end
    end

    # The kinds, one per line, for a refusal.
    def self.kinds : String
      String.build do |io|
        io << "Each file under app/ is one of these, required in this order (lib/punch/docs/structure.md):"
        Kind.values.each { |kind| io << "\n  " << kind.description }
      end
    end

    # The last segments of every type *source* defines, at any depth.
    def self.defined_types(source : String, path : String, errors : Array(Error)) : Array(String)?
      root = Crystal::Parser.parse(source)
      types = [] of String
      collect(root, types)
      types
    rescue ex : Crystal::SyntaxException
      errors << Error.new(Location.new(path, ex.line_number, ex.column_number), "#{ex.message}")
      nil
    end

    private def self.collect(node : Crystal::ASTNode, types : Array(String)) : Nil
      case node
      when Crystal::Expressions
        node.expressions.each { |child| collect(child, types) }
      when Crystal::ModuleDef, Crystal::ClassDef
        types << node.name.names.last
        collect(node.body, types)
      when Crystal::EnumDef
        types << node.name.names.last
      when Crystal::Alias
        types << node.name.names.last
      when Crystal::AnnotationDef
        types << node.name.names.last
      when Crystal::Call
        # `record Name, …` defines a struct.
        if node.name == "record" && node.obj.nil? && (first = node.args.first?).is_a?(Crystal::Path)
          types << first.names.last
        end
      end
    end

    private def self.render(files : Array({String, Kind})) : String
      String.build do |io|
        io << "# Generated by `punch requires:generate` from the files under app/. Do not edit:\n"
        io << "# add, move, or remove files and run it again (lib/punch/docs/structure.md).\n"
        current = nil
        files.each do |file, kind|
          unless kind == current
            io << "\n# " << kind.description << '\n'
            current = kind
          end
          io << "require \"./" << file.rchop(".cr") << "\"\n"
        end
      end
    end
  end
end
