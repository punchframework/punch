require "compiler/crystal/syntax"

module Punch::QueryGen
  # How domain primitives are stored, as far as the generator can see
  # without compiling the app: Punch's own, the app's typed IDs (`struct
  # ID < Punch::TypedID`, `Int64`), and every type under `app/` or `src/`
  # that includes `Punch::Primitive(S)`. A typed path into a document that
  # ends at a field of such a type needs it, since SQLite returns the
  # stored value (docs/composites.md). Read once, when first asked.
  class Primitives
    OWN = {
      "Punch::Email" => "String", "Punch::NonEmptyString" => "String", "Punch::Slug" => "String",
      "Punch::Money" => "Int64", "Punch::Currency" => "String", "Punch::LikeText" => "String",
      "Punch::FtsPhrase" => "String", "Punch::IdempotencyKey" => "String",
    }

    @stored : Hash(String, String)?

    def initialize(@root : String = ".")
    end

    # `String`, `Int64`, or `Float64` for *name*; `nil` when unknown.
    def stored(name : String) : String?
      (@stored ||= scan)[name.lchop("::")]?
    end

    private def scan : Hash(String, String)
      found = OWN.dup
      Dir.glob("#{@root}/{app,src}/**/*.cr").each do |path|
        next if path.ends_with?(".gen.cr")
        node = begin
          Crystal::Parser.parse(File.read(path))
        rescue Crystal::SyntaxException
          next
        end
        collect(node, [] of String, found)
      end
      found
    end

    private def collect(node : Crystal::ASTNode, scope : Array(String), found : Hash(String, String)) : Nil
      case node
      when Crystal::Expressions then node.expressions.each { |child| collect(child, scope, found) }
      when Crystal::ModuleDef   then collect(node.body, scope + node.name.names, found)
      when Crystal::ClassDef
        name = scope + node.name.names
        if node.superclass.to_s.lchop("::").in?("Punch::TypedID", "TypedID")
          found[name.join("::")] = "Int64"
        end
        each_include(node.body) do |included|
          next unless included.is_a?(Crystal::Generic) && included.name.to_s.lchop("::").in?("Punch::Primitive", "Primitive")
          stored = included.type_vars.first?.to_s
          found[name.join("::")] = stored if stored.in?("String", "Int64", "Float64")
        end
        collect(node.body, name, found)
      end
    end

    private def each_include(body : Crystal::ASTNode, & : Crystal::ASTNode ->) : Nil
      nodes = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
      nodes.each { |node| yield node.as(Crystal::Include).name if node.is_a?(Crystal::Include) }
    end
  end
end
