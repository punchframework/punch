module Punch::QueryGen
  module Emitter
    # `composites.gen.cr`: the composites one `composites.cr` declares.
    def self.composite_file(schema : Schema, composites : Array(Composite), source : String) : String
      String.build do |io|
        header(io, source)
        composite_structs(io, schema, composites)
      end
    end

    # The structs of *composites*, polymorphic ones before their members,
    # then a line per default that parses it at program start.
    def self.composite_structs(io : IO, schema : Schema, composites : Array(Composite)) : Nil
      ordered = composites.select(&.polymorphic?) + composites.reject(&.polymorphic?)
      ordered.each_with_index do |composite, index|
        io << '\n' if index > 0
        composite.polymorphic? ? polymorphic_struct(io, composite) : composite_struct(io, schema, composite)
      end
      defaults = ordered.flat_map { |composite| composite.fields.select(&.default).map { |field| "#{composite.name}::#{default_constant(field)}" } }
      return if defaults.empty?

      io << "\n# Each default parses once at program start, so one that does not fails every run at once.\n"
      defaults.each { |constant| io << constant << '\n' }
    end

    private def self.default_constant(field : CompositeField) : String
      "PUNCH_DEFAULT_#{field.name.upcase}"
    end

    private def self.open_module(io : IO, composite : Composite) : Nil
      composite.parent_module.try { |parent| io << "module " << parent << '\n' }
    end

    private def self.close_module(io : IO, composite : Composite) : Nil
      io << "end\n" if composite.parent_module
    end

    private def self.declared_at(composite : Composite) : String
      "#{composite.location.file}:#{composite.location.line}"
    end

    # A composite with its fields: getters, `build`, `copy_with`, equality,
    # its answer (`to_json`), its stored document, its group of columns,
    # and its schema.
    private def self.composite_struct(io : IO, schema : Schema, composite : Composite) : Nil
      fields = composite.fields
      open_module(io, composite)
      io << "  # Declared with `Punch.composite` in " << declared_at(composite) << ". Its behaviour goes in\n"
      io << "  # `" << QueryGen.behaviour_file(composite.name).rchop("/record.cr") << ".cr`, which reopens this struct.\n"
      io << "  struct " << composite.short_name << '\n'
      io << "    include Punch::Composite\n\n"
      io << "    # :nodoc:\n    PUNCH_VERSION = " << composite.version << '\n'
      io << "    # :nodoc:\n    PUNCH_MAX_BYTES = " << composite.max_bytes << '\n'
      io << "    # :nodoc:\n    PUNCH_MAX_DEPTH = " << composite.max_depth << '\n'
      io << "    # :nodoc:\n    PUNCH_DOCUMENT = " << composite.document? << '\n'
      unless composite.frozen.empty?
        io << "    # :nodoc:\n    PUNCH_FROZEN = {" << composite.frozen.keys.sort!.join(", ") { |old| "#{old} => ::#{composite.frozen[old]}" } << "}\n"
      end
      composite.family.try do |family|
        io << "    # :nodoc:\n    PUNCH_DISCRIMINATOR = " << family.discriminator.inspect << '\n'
        io << "    # :nodoc:\n    PUNCH_TAG = " << composite.tag.inspect << '\n'
      end
      fields.select(&.default).each do |field|
        io << "    # :nodoc:\n    " << default_constant(field) << " = Punch::Composite.default(" << field.type.name << ", " << field.default
        io << ", " << "#{field.location.file}:#{field.location.line}".inspect << ")\n"
      end
      io << '\n'
      # A `Bool` field reads as the column of a record does (`row.express`),
      # not as a query method.
      fields.each do |field|
        io << "    getter " << field.name << " : " << field.type.crystal
        io << " # ameba:disable Naming/QueryBoolMethods" if field.type.crystal == "Bool"
        io << '\n'
      end
      io << "    @punch_unknown : Punch::Composite::UnknownKeys?\n\n"
      io << "    private def initialize(" << fields.join(", ") { |field| "@#{field.name} : #{field.type.crystal}" }
      io << ", @punch_unknown : Punch::Composite::UnknownKeys? = nil)\n    end\n\n"
      build_method(io, composite)
      copy_method(io, composite)
      equality(io, composite)
      answer(io, composite)
      bounds(io, composite)
      store(io, composite)
      parse(io, composite)
      read(io, composite)
      group_reader(io, composite) if composite.grouped?
      composite_schema(io, composite)
      io << "  end\n"
      close_module(io, composite)
    end

    private def self.field_parameter(field : CompositeField) : String
      default = if field.default
                  " = #{default_constant(field)}"
                elsif field.type.nilable?
                  " = nil"
                else
                  ""
                end
      "#{field.name} : #{field.type.crystal}#{default}"
    end

    private def self.build_method(io : IO, composite : Composite) : Nil
      fields = composite.fields
      io << "    # Makes one from its fields, checked for its bounds and its own `check`: the only way to make one.\n"
      io << "    def self.build(*, " << fields.join(", ") { |field| field_parameter(field) } << ") : self | Punch::Invalid\n"
      io << "      Punch::Composite.checked(new(" << fields.join(", ", &.name) << "))\n"
      io << "    end\n\n"
    end

    private def self.copy_method(io : IO, composite : Composite) : Nil
      fields = composite.fields
      io << "    # A copy with the given fields changed, checked again. Keys of a stored document that\n"
      io << "    # this release does not know stay, so writing it back loses nothing a newer one added.\n"
      io << "    def copy_with(*, " << fields.join(", ") { |field| "#{field.name} : #{field.type.crystal} = @#{field.name}" } << ") : self | Punch::Invalid\n"
      io << "      Punch::Composite.checked(" << composite.short_name << ".punch_new(" << fields.join(", ", &.name) << ", @punch_unknown))\n"
      io << "    end\n\n"
      io << "    protected def self.punch_new(" << fields.join(", ") { |field| "#{field.name} : #{field.type.crystal}" } << ", unknown : Punch::Composite::UnknownKeys?) : self\n"
      io << "      new(" << fields.join(", ", &.name) << ", unknown)\n"
      io << "    end\n\n"
    end

    private def self.equality(io : IO, composite : Composite) : Nil
      fields = composite.fields
      io << "    # Equal when every declared field is; keys this release does not know do not count.\n"
      io << "    def ==(other : self) : Bool\n"
      io << "      {" << fields.join(", ") { |field| "@#{field.name}" } << "} == {" << fields.join(", ") { |field| "other.#{field.name}" } << "}\n"
      io << "    end\n\n"
      io << "    def hash(hasher)\n"
      io << "      {" << fields.join(", ") { |field| "@#{field.name}" } << "}.hash(hasher)\n"
      io << "    end\n\n"
    end

    # The composite in an answer: its declared fields, `nil` ones left out.
    private def self.answer(io : IO, composite : Composite) : Nil
      io << "    # In an answer: the declared fields under their names, `nil` ones left out.\n"
      io << "    def to_json(json : JSON::Builder) : Nil\n"
      io << "      json.object do\n"
      discriminate(io, composite)
      composite.fields.each { |field| io << "        Punch::Composite.write(json, " << field.name.inspect << ", @" << field.name << ")\n" }
      io << "      end\n"
      io << "    end\n\n"
    end

    private def self.discriminate(io : IO, composite : Composite) : Nil
      family = composite.family || return
      io << "        json.field " << family.discriminator.inspect << ", " << composite.tag.inspect << '\n'
    end

    # Arrays and maps over their bound: `too_many`, as `build` refuses it.
    private def self.bounds(io : IO, composite : Composite) : Nil
      lists = composite.fields.select(&.type.max)
      return if lists.empty?

      io << "    # :nodoc:\n"
      io << "    def punch_bounds : Punch::Invalid?\n"
      lists.each do |field|
        max = field.type.max
        size = field.type.nilable? ? "(@#{field.name}.try(&.size) || 0)" : "@#{field.name}.size"
        io << "      return Punch::Invalid.new(\"too_many\", max: " << max << ", field: " << field.name.inspect << ") if " << size << " > " << max << '\n'
      end
      io << "      nil\n"
      io << "    end\n\n"
    end

    # The stored document: its version when above 1, its member tag, its
    # fields, and the keys it was read with that this release does not know.
    private def self.store(io : IO, composite : Composite) : Nil
      io << "    # :nodoc:\n"
      io << "    def punch_store(json : JSON::Builder) : Nil\n"
      io << "      json.object do\n"
      io << "        json.field " << "$v".inspect << ", " << composite.version << '\n' if composite.version > 1
      discriminate(io, composite)
      composite.fields.each { |field| io << "        Punch::Composite.store(json, " << field.name.inspect << ", @" << field.name << ")\n" }
      io << "        Punch::Composite.store_unknown(json, @punch_unknown)\n"
      io << "      end\n"
      io << "    end\n\n"
    end

    # Reads a stored object of any version this release knows.
    private def self.parse(io : IO, composite : Composite) : Nil
      io << "    # :nodoc:\n"
      io << "    def self.punch_parse(object : Hash(String, JSON::Any), path : String) : self\n"
      io << "      case version = Punch::Composite.version(object, path)\n"
      io << "      when " << composite.version << " then punch_read(object, path)\n"
      composite.frozen.keys.sort!.reverse!.each do |old|
        io << "      when " << old << " then Punch::Composite.frozen(self, ::" << composite.frozen[old] << ", object, path)\n"
      end
      io << "      else Punch::Composite.unreadable_version(" << composite.version << ", version, path)\n"
      io << "      end\n"
      io << "    end\n\n"
    end

    # Reads the current version's fields.
    private def self.read(io : IO, composite : Composite) : Nil
      known = composite.fields.map(&.name)
      composite.family.try(&.discriminator).try { |key| known << key }
      io << "    # :nodoc:\n"
      io << "    def self.punch_read(object : Hash(String, JSON::Any), path : String) : self\n"
      io << "      Punch::Composite.verified(new(\n"
      composite.fields.each do |field|
        io << "        Punch::Composite.read(object, " << field.name.inspect << ", " << field.type.crystal << ", path"
        io << ", " << default_constant(field) if field.default
        io << ", max: " << field.type.max if field.type.max
        io << "),\n"
      end
      io << "        Punch::Composite.unknown(object, {" << known.join(", ", &.inspect) << "}),\n"
      io << "      ), path)\n"
      io << "    end\n\n"
    end

    # Builds one from the columns of a group, read and parsed one by one.
    private def self.group_reader(io : IO, composite : Composite) : Nil
      io << "    # :nodoc:\n"
      io << "    def self.punch_group(" << composite.fields.join(", ") { |field| "#{field.name} : #{field.type.crystal}" }
      io << ", table : String, prefix : String, row_id : Int64?) : self\n"
      io << "      Punch::Composite.grouped(new(" << composite.fields.join(", ", &.name) << "), table, prefix, row_id)\n"
      io << "    end\n\n"
    end

    private def self.composite_schema(io : IO, composite : Composite) : Nil
      io << "    # :nodoc:\n"
      io << "    def self.punch_schema(registry : Punch::JSONSchema::Registry) : JSON::Any\n"
      io << "      registry.define(" << composite.name.inspect << ") do\n"
      io << "        properties = {} of String => JSON::Any\n"
      io << "        required = [] of String\n"
      composite.family.try do |family|
        key = family.discriminator.inspect
        io << "        properties[" << key << "] = Punch::JSONSchema.object({\"type\" => JSON::Any.new(\"string\"), \"const\" => JSON::Any.new(" << composite.tag.inspect << ")})\n"
        io << "        required << " << key << '\n'
      end
      composite.fields.each do |field|
        schema = "registry.schema(#{field.type.crystal})"
        if max = field.type.max
          schema = "Punch::JSONSchema.bounded(#{schema}, #{(field.type.kind.array? ? "maxItems" : "maxProperties").inspect}, #{max})"
        end
        io << "        properties[" << field.name.inspect << "] = " << schema << '\n'
        if field.default
          io << "        required << " << field.name.inspect << " unless registry.payloads?\n"
        elsif !field.type.nilable?
          io << "        required << " << field.name.inspect << '\n'
        end
      end
      io << "        Punch::JSONSchema.composite(properties, required)\n"
      io << "      end\n"
      io << "    end\n"
    end

    # A polymorphic composite: the union of its members, which the
    # compiler checks `case … in` over; each member carries its tag and the
    # key that names it in a stored object.
    private def self.polymorphic_struct(io : IO, composite : Composite) : Nil
      open_module(io, composite)
      io << "  # Declared with `Punch.composite` in " << declared_at(composite) << ": one of\n"
      io << "  # " << composite.members.join(", ") { |tag, name| "`#{name}` (#{tag})" } << ", named by " << composite.discriminator.inspect << ".\n"
      io << "  # Branch on it with `case … in`, member by member.\n"
      io << "  alias " << composite.short_name << " = " << composite.members.join(" | ") { |_, name| "::#{name}" } << '\n'
      close_module(io, composite)
    end
  end
end
