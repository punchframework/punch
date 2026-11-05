require "compiler/crystal/syntax"
require "json"

module Punch::QueryGen
  # The type of one field of a composite (docs/composites.md).
  class FieldType
    enum Kind
      # A domain primitive, `Time`, `Bool`, `String`, `Int64`, or `Float64`.
      Scalar
      Composite
      # `Punch::Encrypted(T)`: a field of its own key in a group of
      # columns, or plain inside an encrypted document; read as
      # `Punch::Secret(T)`.
      Secret
      # A bounded array, `{type: Array(T), max: N}`.
      Array
      # A bounded map, `{type: Hash(K, V), max: N}`.
      Map
    end

    getter kind : Kind
    # The scalar's, composite's, or encrypted value's type as written.
    getter name : String
    # The element of an array, the value of a map.
    getter element : FieldType?
    # The key of a map.
    getter key : String?
    getter max : Int32?
    getter? nilable : Bool

    def initialize(@kind : Kind, @name : String = "", @element : FieldType? = nil, @key : String? = nil, @max : Int32? = nil, @nilable : Bool = false)
    end

    def nilable(flag : Bool) : FieldType
      FieldType.new(kind, name, element, key, max, flag)
    end

    # The Crystal type of the field's getter.
    def crystal : String
      base = case kind
             in .scalar?, .composite? then name
             in .secret?              then "Punch::Secret(#{name})"
             in .array?               then "Array(#{element.try(&.crystal)})"
             in .map?                 then "Hash(#{key}, #{element.try(&.crystal)})"
             end
      nilable? ? "#{base}?" : base
    end

    # Every composite this type holds, directly or as elements.
    def composites : Array(String)
      case kind
      in .composite?        then [name]
      in .array?, .map?     then element.try(&.composites) || [] of String
      in .scalar?, .secret? then [] of String
      end
    end

    def secret? : Bool
      kind.secret? || !!element.try(&.secret?)
    end
  end

  # One field of a composite. *default* is the literal as written, *value*
  # the same as JSON, for comparing with a column's `DEFAULT`.
  record CompositeField, name : String, type : FieldType, default : String?, value : JSON::Any?, location : Location

  # A `Punch.composite` declaration (docs/composites.md): a value type the
  # generator writes as a struct, stored as a group of columns or a JSON
  # document, as the tables that map it decide. A polymorphic composite
  # has no fields: it names its *members*, composites declared in the same
  # file, and the key that tells them apart.
  class Composite
    getter name : String
    getter location : Location
    # The file that declares it, beside which it is generated.
    getter file : String
    getter fields = [] of CompositeField
    property version = 1
    # Older versions and the frozen types that read them.
    getter frozen = {} of Int32 => String
    property max_bytes = Composites::DEFAULT_BYTES
    # `Punch::Composite::MAX_DEPTH`, the deepest document it reads.
    property max_depth = Composites::DEFAULT_DEPTH
    # A polymorphic composite's key, such as `kind`, and its members by tag.
    property discriminator : String? = nil
    getter members = [] of {String, String}
    # A member's polymorphic composite, and its tag there.
    property family : Composite? = nil
    property tag : String? = nil
    # Stored inside a JSON document somewhere, so locked with its versions.
    property? document = false
    # Stored in a group of columns somewhere.
    property? grouped = false

    def initialize(@name : String, @location : Location, @file : String)
    end

    def polymorphic? : Bool
      !discriminator.nil?
    end

    def field(name : String) : CompositeField?
      fields.find(&.name.==(name))
    end

    # `Billing` for `Billing::Address`.
    def parent_module : String?
      parts = name.split("::")
      parts.size > 1 ? parts[0...-1].join("::") : nil
    end

    def short_name : String
      name.split("::").last
    end
  end

  # Reads every `Punch.composite` of an app's `composites.cr` and
  # `columns.cr` files with Crystal's parser, without compiling the app,
  # and checks them as a whole: names, field types, bounds, defaults,
  # versions, polymorphic members, and that no composite contains itself.
  module Composites
    OPTIONS = %w[version from max_bytes max_depth discriminator one_of]

    # Types a field cannot have: what JSON and the columns cannot hold as
    # a composite stores it, and what Punch has no stored form for.
    REFUSED = %w[Bytes Slice(UInt8) Int32 Int8 Int16 UInt8 UInt16 UInt32 UInt64 Float32 Char Symbol Nil JSON::Any]

    # Most elements a bound may allow, and most bytes a document may have.
    MAX_ELEMENTS = 10_000
    MAX_BYTES    = 1024 * 1024
    # `Punch::Composite::MAX_BYTES`, a document's size unless it says.
    DEFAULT_BYTES = 16 * 1024
    # `Punch::Composite::MAX_DEPTH` and `DEPTH_LIMIT`: a document's nesting
    # unless it says, and the most it may say.
    DEFAULT_DEPTH = 32
    DEPTH_LIMIT   = 64

    # The composites Punch ships, and where they are declared: known in
    # every app, and generated only in Punch itself, where the file is
    # among the ones `files` finds.
    OWN_PATH   = "src/punch/upload/composites.cr"
    OWN_SOURCE = {{ read_file("#{__DIR__}/../upload/composites.cr") }}

    def self.files(root : String = ".") : Array(String)
      Dir.glob("#{root}/{app,src}/**/composites.cr").map { |path| ::Path[path].relative_to(root).to_s }.sort!
    end

    # Every composite declared in *paths*, by name.
    def self.collect(paths : Array(String), errors : Array(Error)) : Hash(String, Composite)
      calls = [] of {Composite, Crystal::Call}
      sources = paths.map { |path| {path, File.read(path)} }
      # Only Punch's own file stands in for the declarations; an app's file
      # at that path declares them twice.
      sources << {OWN_PATH, OWN_SOURCE} unless sources.includes?({OWN_PATH, OWN_SOURCE})
      sources.each do |path, source|
        root = begin
          Crystal::Parser.parse(source)
        rescue ex : Crystal::SyntaxException
          # A columns.cr reports its own when the mapping parses it.
          errors << Error.new(Location.new(path, ex.line_number, ex.column_number), "#{ex.message}") if File.basename(path) == "composites.cr"
          next
        end
        nodes = root.is_a?(Crystal::Expressions) ? root.expressions : [root]
        nodes.each do |node|
          if composite_call?(node)
            declared(node.as(Crystal::Call), path, errors).try { |composite| calls << {composite, node.as(Crystal::Call)} }
          elsif File.basename(path) == "composites.cr" && !node.is_a?(Crystal::Require) && !node.is_a?(Crystal::Nop)
            errors << error(path, node, "#{path} may only contain `Punch.composite Name, field: Type, …` calls")
          end
        end
      end
      composites = by_name(calls.map(&.first), errors)
      calls.each { |composite, call| arguments(composite, call, composites, errors) if composites[composite.name]? == composite }
      composites.each_value { |composite| link_members(composite, composites, errors) }
      composites.each_value { |composite| check_cycle(composite, composites, errors) }
      composites.each_value { |composite| check_depth(composite, composites, errors) } if errors.empty?
      composites
    end

    # *declared* by name; a name declared twice is an error.
    private def self.by_name(declared : Array(Composite), errors : Array(Error)) : Hash(String, Composite)
      composites = {} of String => Composite
      declared.each do |composite|
        if other = composites[composite.name]?
          errors << Error.new(composite.location, "#{composite.name} is declared twice; the other is at #{other.location}")
        else
          composites[composite.name] = composite
          # Its users are in other apps, so it always reads from columns.
          composite.grouped = true if composite.file == OWN_PATH
        end
      end
      composites
    end

    def self.composite_call?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::Call) && node.name == "composite" && node.obj.to_s.lchop("::") == "Punch"
    end

    # The composite a call declares, checked for its name and namespace.
    private def self.declared(call : Crystal::Call, path : String, errors : Array(Error)) : Composite?
      name = call.args.first?
      unless call.args.size == 1 && name.is_a?(Crystal::Path)
        errors << error(path, call, "Punch.composite takes the composite's name, then `field: Type` pairs")
        return
      end
      full = name.to_s.lchop("::")
      if (namespace = QueryGen.namespace(path)) && full != namespace && !full.starts_with?("#{namespace}::")
        errors << error(path, name, "#{path} declares only composites of #{namespace}, such as #{namespace}::#{name.names.last}")
        return
      end
      if full.count("::") == 0
        errors << error(path, name, "#{full} needs a namespace, such as Billing::#{full}")
        return
      end
      Composite.new(full, location(path, call), path)
    end

    # Fields and options: an option's value is a literal (`version: 2`), a
    # field's a type (`version: Int64`), so a field may have any name.
    private def self.arguments(composite : Composite, call : Crystal::Call, composites : Hash(String, Composite), errors : Array(Error)) : Nil
      path = composite.file
      (call.named_args || [] of Crystal::NamedArgument).each do |argument|
        value = argument.value
        if option?(argument.name, value)
          option(composite, argument, composites, errors)
        elsif !QueryGen.identifier?(argument.name) || argument.name.starts_with?("punch")
          errors << error(path, argument, "#{composite.name}.#{argument.name} is not a field name: a field is a lowercase Crystal name not starting with punch")
        elsif type = field_type(value, composites, path, errors, "#{composite.name}.#{argument.name}")
          default, json = default_of(value, type, path, errors, "#{composite.name}.#{argument.name}")
          composite.fields << CompositeField.new(argument.name, type, default, json, location(path, argument))
        end
      end
      if composite.polymorphic?
        errors << Error.new(composite.location, "#{composite.name} is polymorphic, so it has members (one_of:), not fields") unless composite.fields.empty?
        errors << Error.new(composite.location, "#{composite.name}: a polymorphic composite has no versions of its own; each member has its") unless composite.version == 1
        errors << Error.new(composite.location, "#{composite.name}: discriminator: and one_of: go together") if composite.members.empty?
      elsif !composite.members.empty?
        errors << Error.new(composite.location, "#{composite.name}: one_of: needs discriminator: \"kind\", the key that names the member")
      elsif composite.fields.empty?
        errors << Error.new(composite.location, "#{composite.name} has no fields")
      end
      check_versions(composite, errors)
    end

    private def self.option?(name : String, value : Crystal::ASTNode) : Bool
      return false unless OPTIONS.includes?(name)

      value.is_a?(Crystal::NumberLiteral) || value.is_a?(Crystal::HashLiteral) || value.is_a?(Crystal::StringLiteral) || value.is_a?(Crystal::NamedTupleLiteral)
    end

    private def self.option(composite : Composite, argument : Crystal::NamedArgument, composites : Hash(String, Composite), errors : Array(Error)) : Nil
      value = argument.value
      case argument.name
      when "version"
        number = bounded_number(composite, value, 1000, "version: is a number from 1 to 1000", errors) || return
        composite.version = number
      when "max_bytes"
        number = bounded_number(composite, value, MAX_BYTES, "max_bytes: is a number of bytes up to #{MAX_BYTES}", errors) || return
        composite.max_bytes = number
      when "max_depth"
        number = bounded_number(composite, value, DEPTH_LIMIT, "max_depth: is how deep its documents nest, from 1 to #{DEPTH_LIMIT}", errors) || return
        composite.max_depth = number
      when "from"          then frozen_types(composite, value, errors)
      when "discriminator" then discriminator(composite, value, errors)
      when "one_of"        then members(composite, value, errors)
      end
    end

    private def self.bounded_number(composite : Composite, value : Crystal::ASTNode, max : Int32, message : String, errors : Array(Error)) : Int32?
      number = value.as?(Crystal::NumberLiteral).try(&.value.to_i?)
      return number if number && 1 <= number <= max

      errors << error(composite.file, value, "#{composite.name}: #{message}")
      nil
    end

    # `from: {1 => V1}`: the frozen type of each older version.
    private def self.frozen_types(composite : Composite, value : Crystal::ASTNode, errors : Array(Error)) : Nil
      unless value.is_a?(Crystal::HashLiteral)
        errors << error(composite.file, value, "#{composite.name}: from: maps older versions to frozen types, such as from: {1 => #{composite.name}::V1}")
        return
      end
      value.entries.each do |entry|
        old = entry.key.as?(Crystal::NumberLiteral).try(&.value.to_i?)
        type = entry.value.as?(Crystal::Path)
        if old && type
          composite.frozen[old] = type.to_s.lchop("::")
        else
          errors << error(composite.file, entry.key, "#{composite.name}: from: maps a version number to a frozen type, such as 1 => #{composite.name}::V1")
        end
      end
    end

    private def self.discriminator(composite : Composite, value : Crystal::ASTNode, errors : Array(Error)) : Nil
      key = value.as?(Crystal::StringLiteral).try(&.value)
      if key && QueryGen.identifier?(key)
        composite.discriminator = key
      else
        errors << error(composite.file, value, "#{composite.name}: discriminator: is the key that names the member, such as \"kind\"")
      end
    end

    # `one_of: {card: Billing::Card}`: the members by tag.
    private def self.members(composite : Composite, value : Crystal::ASTNode, errors : Array(Error)) : Nil
      unless value.is_a?(Crystal::NamedTupleLiteral)
        errors << error(composite.file, value, "#{composite.name}: one_of: names each member by its tag, such as one_of: {card: Billing::Card}")
        return
      end
      value.entries.each do |entry|
        member = entry.value.as?(Crystal::Path)
        if member && entry.key.matches?(/\A[a-z][a-z0-9_]*\z/)
          composite.members << {entry.key, member.to_s.lchop("::")}
        else
          errors << error(composite.file, entry.value, "#{composite.name}: one_of: takes `tag: Composite` pairs, with lowercase tags")
        end
      end
    end

    # Versions above 1 name a frozen type for each older one.
    private def self.check_versions(composite : Composite, errors : Array(Error)) : Nil
      composite.frozen.each_key do |old|
        next if 1 <= old < composite.version
        errors << Error.new(composite.location, "#{composite.name}: from: maps versions below #{composite.version} to frozen types; #{old} is not one")
      end
    end

    # The type of a field, as written: `T`, `T?`, `Punch::Encrypted(T)`, or
    # `{type: T, default: …}` / `{type: Array(T), max: N}`.
    def self.field_type(node : Crystal::ASTNode, composites : Hash(String, Composite), path : String, errors : Array(Error), what : String) : FieldType?
      FieldTypes.new(composites, path, errors, what).read(node)
    end

    # Reads one field's type, reporting what it refuses as *what*.
    private class FieldTypes
      # Map keys that are not text.
      NOT_KEYS = %w[Time Bool Int64 Float64]

      def initialize(@composites : Hash(String, Composite), @path : String, @errors : Array(Error), @what : String)
      end

      def read(node : Crystal::ASTNode) : FieldType?
        return type_of(node, nil) unless node.is_a?(Crystal::NamedTupleLiteral)

        type = node.entries.find(&.key.==("type")).try(&.value)
        max = node.entries.find(&.key.==("max")).try(&.value)
        unless type && (node.entries.map(&.key) - %w[type default max]).empty?
          return fail(node, "a field with options is {type: T, default: literal} or {type: Array(T), max: N}")
        end
        return type_of(type, nil) unless max

        bound = max.as?(Crystal::NumberLiteral).try(&.value.to_i?)
        return fail(max, "max: is a number from 1 to #{MAX_ELEMENTS}") unless bound && 1 <= bound <= MAX_ELEMENTS

        type_of(type, bound)
      end

      private def type_of(node : Crystal::ASTNode, max : Int32?) : FieldType?
        if node.is_a?(Crystal::Generic)
          generic = node.name.to_s.lchop("::")
          return nilable(node, max) if generic == "Union"
          return generic_type(node, generic, node.type_vars, max)
        end
        return fail(node, "the type must be a constant, such as Punch::NonEmptyString") unless node.is_a?(Crystal::Path)

        name = node.to_s.lchop("::")
        return fail(node, "#{name} cannot be a field; use a domain primitive, Time, Bool, Int64, Float64, or String") if Composites.refused?(name)

        type = FieldType.new(@composites.has_key?(name) ? FieldType::Kind::Composite : FieldType::Kind::Scalar, name)
        unbounded(type, max, node)
      end

      # `T?`, which Crystal's parser reads as `::Union(T, ::Nil)`.
      private def nilable(node : Crystal::Generic, max : Int32?) : FieldType?
        vars = node.type_vars
        return fail(node, "a field is one type, optionally nilable (T?)") unless vars.size == 2 && vars.last.to_s.lchop("::") == "Nil"

        type_of(vars.first, max).try(&.nilable(true))
      end

      private def generic_type(node : Crystal::Generic, generic : String, vars : Array(Crystal::ASTNode), max : Int32?) : FieldType?
        case generic
        when "Punch::Encrypted"
          inner = vars.first?.as?(Crystal::Path).try(&.to_s.lchop("::")) if vars.size == 1
          return fail(node, "Punch::Encrypted takes one domain primitive, Time, Bool, or stored type") if inner.nil? || @composites.has_key?(inner) || Composites.refused?(inner)
          unbounded(FieldType.new(:secret, inner), max, node)
        when "Array" then array_type(node, vars, max)
        when "Hash"  then map_type(node, vars, max)
        else
          fail(node, "#{generic} cannot be a field; use a domain primitive, Time, Bool, Int64, Float64, String, a composite, or a bounded Array or Hash")
        end
      end

      private def array_type(node : Crystal::Generic, vars : Array(Crystal::ASTNode), max : Int32?) : FieldType?
        return fail(node, "an array is bounded: {type: Array(T), max: N}") unless max

        element = vars.size == 1 ? element_type(vars.first) : nil
        FieldType.new(:array, element: element, max: max) if element
      end

      private def map_type(node : Crystal::Generic, vars : Array(Crystal::ASTNode), max : Int32?) : FieldType?
        return fail(node, "a map is bounded: {type: Hash(K, V), max: N}") unless max

        key = vars.first?.as?(Crystal::Path).try(&.to_s.lchop("::")) if vars.size == 2
        return fail(node, "a map's key is String or a domain primitive stored as String") unless key && text_key?(key)

        element = element_type(vars[1]) || return
        FieldType.new(:map, element: element, key: key, max: max)
      end

      private def text_key?(key : String) : Bool
        !(@composites.has_key?(key) || Composites.refused?(key) || NOT_KEYS.includes?(key))
      end

      # An array's element or a map's value: a scalar or a composite, never
      # nilable, never itself a list.
      private def element_type(node : Crystal::ASTNode) : FieldType?
        type = type_of(node, nil) || return
        return type if type.kind.scalar? || type.kind.composite? && !type.nilable?

        fail(node, "an element is a domain primitive, Time, Bool, Int64, Float64, String, or a composite, not nilable")
      end

      private def unbounded(type : FieldType, max : Int32?, node : Crystal::ASTNode) : FieldType?
        max ? fail(node, "max: bounds an Array or a Hash") : type
      end

      private def fail(node : Crystal::ASTNode, message : String) : Nil
        @errors << Composites.error(@path, node, "#{@what}: #{message}")
        nil
      end
    end

    def self.refused?(name : String) : Bool
      REFUSED.includes?(name)
    end

    # The default of `{type: T, default: literal}`, as Crystal and as JSON.
    private def self.default_of(node : Crystal::ASTNode, type : FieldType, path : String, errors : Array(Error), what : String) : {String?, JSON::Any?}
      return {nil, nil} unless node.is_a?(Crystal::NamedTupleLiteral)
      literal = node.entries.find(&.key.==("default")).try(&.value) || return {nil, nil}

      if !type.kind.scalar? || type.nilable?
        errors << error(path, literal, "#{what}: only a field that is a domain primitive, Time, Bool, or a stored type, not nilable, has a default")
        return {nil, nil}
      end
      json = case literal
             when Crystal::StringLiteral then JSON::Any.new(literal.value)
             when Crystal::BoolLiteral   then JSON::Any.new(literal.value)
             when Crystal::NumberLiteral
               literal.kind.f32? || literal.kind.f64? ? JSON::Any.new(literal.value.to_f64) : literal.value.to_i64?.try { |number| JSON::Any.new(number) }
             end
      unless json
        errors << error(path, literal, "#{what}: a default is a string, number, or true/false literal")
        return {nil, nil}
      end
      {literal.to_s, json}
    end

    # A polymorphic composite's members: composites, each in one family
    # only, with no field named like the discriminator.
    private def self.link_members(composite : Composite, composites : Hash(String, Composite), errors : Array(Error)) : Nil
      key = composite.discriminator || return
      tags = Set(String).new
      composite.members.each do |tag, name|
        member = composites[name]?
        unless member
          errors << Error.new(composite.location, "#{composite.name}: its member #{name} is not a composite; declare it with Punch.composite")
          next
        end
        errors << Error.new(composite.location, "#{composite.name}: the tag #{tag} is used twice") unless tags.add?(tag)
        if member.polymorphic?
          errors << Error.new(composite.location, "#{composite.name}: its member #{name} is polymorphic itself; list that one's members instead")
        elsif other = member.family
          errors << Error.new(composite.location, "#{name} is a member of #{other.name} already; a composite belongs to one polymorphic composite")
        elsif clash = member.field(key)
          errors << Error.new(clash.location, "#{name}.#{key}: #{composite.name} names its members by the key #{key}, so a member has no field of that name")
        else
          member.family = composite
          member.tag = tag
          # The alias has no constants: its bounds are its members'.
          member.max_bytes = {member.max_bytes, composite.max_bytes}.max
          member.max_depth = {member.max_depth, composite.max_depth}.max
        end
      end
    end

    # A composite that contains itself, directly or through others, has no
    # end; refused (arrays and maps included).
    private def self.check_cycle(composite : Composite, composites : Hash(String, Composite), errors : Array(Error)) : Nil
      seen = [composite.name]
      stack = [composite]
      until stack.empty?
        current = stack.pop
        held = current.fields.flat_map(&.type.composites) + current.members.map(&.[1])
        held.each do |name|
          if name == composite.name
            errors << Error.new(composite.location, "#{composite.name} contains itself (through #{current.name}); a composite has an end")
            return
          end
          next if seen.includes?(name)
          seen << name
          composites[name]?.try { |other| stack << other }
        end
      end
    end

    # A composite's documents nest at least as deep as its declaration
    # does; a `max_depth:` below that would refuse its own documents.
    private def self.check_depth(composite : Composite, composites : Hash(String, Composite), errors : Array(Error)) : Nil
      needed = depth(composite, composites)
      return if needed <= composite.max_depth

      limit = composite.max_depth == DEFAULT_DEPTH ? "the default, #{DEFAULT_DEPTH}; raise it with max_depth: #{needed}" : "its max_depth: #{composite.max_depth}"
      errors << Error.new(composite.location, "#{composite.name}: its documents nest #{needed} deep, more than #{limit}#{needed > DEPTH_LIMIT ? " (at most #{DEPTH_LIMIT}): store part of it in a child table" : ""}")
    end

    # How deep a document of *composite* nests: 1 for its object, plus its
    # deepest field (an array or map adds 1 for itself).
    def self.depth(composite : Composite, composites : Hash(String, Composite)) : Int32
      return composite.members.max_of? { |_, name| composites[name]?.try { |member| depth(member, composites) } || 1 } || 1 if composite.polymorphic?

      1 + (composite.fields.max_of? { |field| type_depth(field.type, composites) } || 0)
    end

    private def self.type_depth(type : FieldType, composites : Hash(String, Composite)) : Int32
      case type.kind
      in .scalar?, .secret? then 0
      in .composite?        then composites[type.name]?.try { |held| depth(held, composites) } || 1
      in .array?, .map?     then 1 + (type.element.try { |element| type_depth(element, composites) } || 0)
      end
    end

    # Every composite reachable from *name*: itself, its fields', its
    # members', and its polymorphic family's.
    def self.reachable(name : String, composites : Hash(String, Composite)) : Array(Composite)
      found = [] of Composite
      stack = [name]
      until stack.empty?
        current = composites[stack.pop]? || next
        next if found.includes?(current)
        found << current
        current.fields.each { |field| stack.concat(field.type.composites) }
        current.members.each { |_, member| stack << member }
      end
      found
    end

    def self.location(path : String, node : Crystal::ASTNode) : Location
      location = node.location
      Location.new(path, location.try(&.line_number) || 1, location.try(&.column_number))
    end

    def self.error(path : String, node : Crystal::ASTNode, message : String) : Error
      Error.new(location(path, node), message)
    end
  end
end
