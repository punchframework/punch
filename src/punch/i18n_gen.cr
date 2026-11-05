require "yaml"
require "compiler/crystal/syntax"
require "./query_gen"
require "./i18n/plural"
require "./i18n/catalog"

module Punch
  # The generator behind `punch i18n:generate`: reads the app's locale files
  # and Punch's own, and writes one committed file with the app's typed
  # accessors and the catalog of every message. Not part of
  # `require "punch"`.
  #
  # Mistakes that leave nothing to generate (a file that does not parse,
  # a key that cannot be a method name, a locale without plural rules)
  # raise `QueryGen::Errors`. Gaps between locales, messages missing for
  # an error code, and unused keys are findings in the result: the file is
  # written anyway, so the app compiles, and `--check` fails on them.
  module I18nGen
    alias Location = QueryGen::Location
    alias Error = QueryGen::Error
    alias Category = I18n::Category

    DIRECTORY = "config/locales"
    # Punch's own messages, compiled into the tool.
    OWN = {
      "en" => {{ read_file("#{__DIR__}/locales/en.yml") }},
      "de" => {{ read_file("#{__DIR__}/locales/de.yml") }},
    }
    OWN_FILE = "src/punch/locales"
    # Key namespaces Punch reads by name; no accessors, not reported unused.
    RESERVED = %w[punch date time number errors problems fields llms]
    SEGMENT  = /\A[a-z][a-z0-9_]*\z/
    NAME     = /%\{([^}]*)\}/
    # Names a generated method or argument cannot take.
    KEYWORDS = %w[abstract alias annotation as asm begin break case class def do else elsif end ensure enum extend
      false for fun if in include instance_sizeof lib macro module next nil of offsetof out pointerof private
      protected require rescue return select self sizeof struct super then true type typeof uninitialized union
      unless until verbatim when while with yield hash inspect to_s dup clone itself tap try object_id initialize
      new locale]

    # One message, plural message, or list, as one locale's files hold it.
    struct Value
      getter kind : I18n::Catalog::Kind
      # A message's text in `[0]`; a plural's by category; a list's items.
      getter texts : Array(String?)
      getter location : Location

      def initialize(@kind : I18n::Catalog::Kind, @texts : Array(String?), @location : Location)
      end

      # The `%{…}` names its texts use.
      def names : Set(String)
        texts.compact.flat_map(&.scan(NAME).map(&.[1])).to_set
      end

      def plural_categories : Array(Category)
        Category.values.select { |category| texts[category.value]? }
      end
    end

    record Config,
      directory : String = DIRECTORY,
      # Where the app declares `Punch.translations`; `nil` writes Punch's
      # own catalog (`own.gen.cr`).
      declaration : {String, String, String}? = nil,
      sources : Array(String) = [] of String

    # A finding of the check: what is wrong, and where.
    record Finding, location : Location, message : String do
      def to_s(io : IO) : Nil
        io << location << ": " << message
      end
    end

    record Result, output : QueryGen::Output, locales : Array(String), keys : Int32,
      findings : Array(Finding), unused : Array({String, Location})

    # The app's declaration, `Punch.translations Type, default: "en"`, in
    # *sources*: {file, type, default}. `nil` when there is none.
    def self.declaration(sources : Array(String)) : {String, String, String}?
      found = [] of {String, String, String, Location}
      sources.each do |file|
        next unless (source = File.read(file)).includes?("translations")
        each_call(parse(source, file)) do |call|
          next unless call.name == "translations" && call.obj.to_s == "Punch"
          type = call.args[0]?
          default = call.named_args.try(&.find(&.name.==("default"))).try(&.value)
          unless type.is_a?(Crystal::Path) && (default.nil? || default.is_a?(Crystal::StringLiteral))
            raise QueryGen::Errors.new([Error.new(location(file, call), "Punch.translations takes the type to generate and `default: \"en\"`")])
          end
          found << {file, type.to_s, default.as?(Crystal::StringLiteral).try(&.value) || "en", location(file, call)}
        end
      end
      if found.size > 1
        raise QueryGen::Errors.new(found.map { |entry| Error.new(entry[3], "Punch.translations is declared #{found.size} times; declare it once") })
      end
      found.first?.try { |file, type, default, _| {file, type, default} }
    end

    # Where the generated file goes: `translations.gen.cr` next to the
    # declaring file (`app/setup.cr` → `app/translations.gen.cr`), a name
    # the require generator knows.
    def self.output_path(file : String) : String
      File.join(File.dirname(file), "translations.gen.cr")
    end

    def self.run(config : Config) : Result
      declaration = config.declaration
      default = declaration.try(&.[2]) || "en"
      merged = load(config, default)
      tags = merged.keys
      keys = merged[default].keys
      findings = compare(tags, merged, default)
      errors = [] of Error
      validate_accessors(keys, merged[default], errors)
      raise QueryGen::Errors.new(errors) unless errors.empty?

      unless declaration
        output = output("src/punch/i18n/own.gen.cr", own_catalog(tags, keys, merged))
        return Result.new(output, tags, keys.size, findings, [] of {String, Location})
      end
      findings.concat(codes(config.sources, merged[default]))
      unused = unused(config.sources, keys, merged[default])
      content = accessors(declaration[1], default, tags, keys, merged, config.directory)
      Result.new(output(output_path(declaration[0]), content), tags, keys.size, findings, unused)
    end

    private def self.output(path : String, content : String) : QueryGen::Output
      QueryGen::Output.new(path, QueryGen::Emitter.format(content, path))
    end

    # Every locale's values, the default first: Punch's own, with the
    # app's files over them. Raises on files that leave nothing to merge.
    private def self.load(config : Config, default : String) : Hash(String, Hash(String, Value))
      errors = [] of Error
      own = OWN.to_h { |tag, source| {tag, load_source(source, "#{OWN_FILE}/#{tag}.yml", errors)} }
      declaration = config.declaration
      app = declaration ? load_directory(config.directory, errors) : {} of String => Hash(String, Value)
      raise QueryGen::Errors.new(errors) unless errors.empty?
      if declaration && !app.has_key?(default)
        raise QueryGen::Errors.new([Error.new(Location.new(declaration[0], 1), "the default locale is #{default}, but #{config.directory} has no file for it (#{default}: at the root of a .yml file)")])
      end
      others = (declaration ? app.keys : own.keys).reject(&.==(default)).sort!
      tags = [default] + others
      unknown = tags.reject { |tag| I18n::Plural.rule?(tag) }
      unless unknown.empty?
        raise QueryGen::Errors.new(unknown.map { |tag| Error.new(Location.new(config.directory, 1), "no plural rules for the locale #{tag}; Punch knows #{I18n::Plural::RULES.keys.join(", ")}") })
      end
      tags.to_h do |tag|
        values = (own[tag]? || {} of String => Value).dup
        app[tag]?.try &.each { |key, value| values[key] = value }
        {tag, values}
      end
    end

    # Every locale file under *directory*, merged per locale.
    private def self.load_directory(directory : String, errors : Array(Error)) : Hash(String, Hash(String, Value))
      locales = {} of String => Hash(String, Value)
      return locales unless Dir.exists?(directory)

      Dir.glob(File.join(directory, "**", "*.yml")).sort!.each do |file|
        source = File.read(file)
        root = parse_yaml(source, file, errors) || next
        unless root.is_a?(YAML::Nodes::Mapping) && root.nodes.size == 2 && (tag = root.nodes[0]).is_a?(YAML::Nodes::Scalar)
          errors << Error.new(Location.new(file, 1), "a locale file holds one mapping under its locale, such as `en:`")
          next
        end
        values = locales[tag.value] ||= {} of String => Value
        flatten(root.nodes[1], [] of String, file, values, errors)
      end
      locales
    end

    private def self.load_source(source : String, file : String, errors : Array(Error)) : Hash(String, Value)
      values = {} of String => Value
      root = parse_yaml(source, file, errors) || return values
      if root.is_a?(YAML::Nodes::Mapping) && (inner = root.nodes[1]?)
        flatten(inner, [] of String, file, values, errors)
      end
      values
    end

    private def self.parse_yaml(source : String, file : String, errors : Array(Error)) : YAML::Nodes::Node?
      document = YAML::Nodes.parse(source)
      root = document.nodes.first?
      errors << Error.new(Location.new(file, 1), "the file is empty") unless root
      root
    rescue ex : YAML::ParseException
      errors << Error.new(Location.new(file, ex.line_number, ex.column_number), "does not parse: #{ex.message}")
      nil
    end

    private def self.flatten(node : YAML::Nodes::Node, path : Array(String), file : String, values : Hash(String, Value), errors : Array(Error)) : Nil
      location = Location.new(file, node.start_line.to_i32, node.start_column.to_i32)
      key = path.join('.')

      case node
      when YAML::Nodes::Scalar
        if path.empty?
          errors << Error.new(location, "a locale holds a mapping of keys")
        else
          add(values, key, Value.new(:message, [scalar(node)], location), errors)
        end
      when YAML::Nodes::Sequence
        items = node.nodes.map { |item| item.is_a?(YAML::Nodes::Scalar) ? scalar(item) : nil }
        add(values, key, Value.new(:list, items, location), errors)
      when YAML::Nodes::Mapping
        pairs = node.nodes.each_slice(2).map { |pair| {pair[0].as?(YAML::Nodes::Scalar).try(&.value), pair[1]} }.to_a
        if plural = plural(path, pairs, location)
          add(values, key, plural, errors)
        else
          pairs.each do |name, child|
            name ? flatten(child, path + [name], file, values, errors) : (errors << Error.new(location, "keys are plain scalars"))
          end
        end
      else
        errors << Error.new(location, "aliases and anchors are not supported in locale files")
      end
    end

    # A mapping of plural forms (`one`, `other`, …), or `nil` for a
    # namespace.
    private def self.plural(path : Array(String), pairs : Array({String?, YAML::Nodes::Node}), location : Location) : Value?
      forms = pairs.compact_map do |name, form|
        category = name.try { |text| text == text.downcase ? Category.parse?(text) : nil } || return
        {category, form}
      end
      return if path.empty? || forms.none? { |category, _| category.other? }

      texts = Array(String?).new(Category.values.size, nil)
      forms.each { |category, form| texts[category.value] = form.as?(YAML::Nodes::Scalar).try { |scalar| scalar(scalar) } }
      Value.new(:plural, texts, location)
    end

    private def self.add(values : Hash(String, Value), key : String, value : Value, errors : Array(Error)) : Nil
      if earlier = values[key]?
        errors << Error.new(value.location, "#{key} is also defined at #{earlier.location}")
      else
        values[key] = value
      end
    end

    # A scalar's text; `~` and an empty value are `nil`, a missing text.
    private def self.scalar(node : YAML::Nodes::Scalar) : String?
      return if node.style.plain? && node.value.in?("", "~", "null")

      node.value
    end

    # Gaps between each locale and the default, and plural forms a
    # locale's rule needs.
    private def self.compare(tags : Array(String), merged : Hash(String, Hash(String, Value)), default : String) : Array(Finding)
      findings = [] of Finding
      reference = merged[default]
      tags.each do |tag|
        values = merged[tag]
        own = [] of String
        reference.each do |key, expected|
          if value = values[key]?
            compare(tag, key, value, expected, default, findings)
          elsif expected.location.file.starts_with?(OWN_FILE)
            own << key
          else
            findings << Finding.new(expected.location, "#{key} is missing in #{tag}")
          end
        end
        unless own.empty?
          findings << Finding.new(Location.new("#{OWN_FILE}/#{default}.yml", 1),
            "#{tag} lacks #{own.size} of Punch's keys (#{own.first(3).join(", ")}, …): Punch ships en and de; copy #{OWN_FILE}/en.yml into #{DIRECTORY}/#{tag}.yml under `#{tag}:` and translate it")
        end
        values.each do |key, value|
          findings << Finding.new(value.location, "#{tag}.#{key} is not in #{default}, the default locale") unless reference.has_key?(key)
        end
      end
      findings
    end

    # One key of locale *tag* against the default locale's.
    private def self.compare(tag : String, key : String, value : Value, expected : Value, default : String, findings : Array(Finding)) : Nil
      name = "#{tag}.#{key}"
      if value.kind != expected.kind
        findings << Finding.new(value.location, "#{name} is a #{value.kind.to_s.downcase}, but #{expected.kind.to_s.downcase} in #{default}")
        return
      end

      case value.kind
      in .message?
        findings << Finding.new(value.location, "#{name} is empty") if value.texts[0].nil?
      in .plural?
        plural_forms(tag, name, value, findings)
      in .list?
        if value.texts.size != expected.texts.size
          findings << Finding.new(value.location, "#{name} has #{value.texts.size} items, #{expected.texts.size} in #{default}")
        end
      end

      if value.names != expected.names
        findings << Finding.new(value.location, "#{name} uses #{names(value.names)}, but #{default} uses #{names(expected.names)}")
      end
    end

    private def self.plural_forms(tag : String, name : String, value : Value, findings : Array(Finding)) : Nil
      rule = I18n::Plural.rule?(tag) || return
      needed = I18n::Plural.categories(rule)
      have = value.plural_categories
      missing = needed - have
      extra = have - needed - [Category::Zero]
      findings << Finding.new(value.location, "#{name} needs the plural forms #{missing.map(&.to_s.downcase).join(", ")} (rule #{rule})") unless missing.empty?
      findings << Finding.new(value.location, "#{name} has plural forms #{rule} never uses: #{extra.map(&.to_s.downcase).join(", ")}") unless extra.empty?
    end

    private def self.names(names : Set(String)) : String
      names.empty? ? "no arguments" : names.to_a.sort!.join(", ") { |name| "%{#{name}}" }
    end

    private def self.accessor?(key : String) : Bool
      !RESERVED.includes?(key.partition('.')[0])
    end

    # Every key outside Punch's namespaces must make a method, and its
    # `%{…}` names arguments.
    private def self.validate_accessors(keys : Array(String), values : Hash(String, Value), errors : Array(Error)) : Nil
      structs = {} of String => String
      keys.select { |key| accessor?(key) }.each do |key|
        value = values[key]
        segments = key.split('.')
        if bad = segments.find { |segment| !SEGMENT.matches?(segment) || KEYWORDS.includes?(segment) }
          errors << Error.new(value.location, "#{key}: `#{bad}` cannot be a method name; use lowercase letters, digits, and underscores, and no Crystal keyword")
          next
        end
        segments[0...-1].each_with_index do |segment, index|
          scope = segments[0...index].join('.')
          name = "#{scope}/#{camelcase(segment)}"
          if (other = structs[name]?) && other != segment
            errors << Error.new(value.location, "#{key}: `#{segment}` and `#{other}` both become the type #{camelcase(segment)}; rename one")
          end
          structs[name] = segment
        end
        value.names.each do |name|
          next if SEGMENT.matches?(name) && !KEYWORDS.includes?(name)
          errors << Error.new(value.location, "#{key}: `%{#{name}}` cannot be an argument name; use lowercase letters, digits, and underscores")
        end
      end
    end

    private def self.camelcase(segment : String) : String
      segment.camelcase
    end

    # The slots of every key, in order.
    private def self.layout(keys : Array(String), values : Hash(String, Value)) : Hash(String, I18n::Catalog::Entry)
      slot = 0
      keys.to_h do |key|
        value = values[key]
        size = case value.kind
               in .message? then 1
               in .plural?  then Category.values.size
               in .list?    then value.texts.size
               end
        entry = I18n::Catalog::Entry.new(slot, value.kind, value.kind.list? ? size : 1)
        slot += size
        {key, entry}
      end
    end

    private def self.texts(keys : Array(String), values : Hash(String, Value), entries : Hash(String, I18n::Catalog::Entry)) : Array(String?)
      texts = [] of String?
      keys.each do |key|
        entry = entries[key]
        size = entry.kind.plural? ? Category.values.size : entry.size
        value = values[key]?
        size.times do |offset|
          texts << (value && value.kind == entry.kind ? value.texts[offset]? : nil)
        end
      end
      texts
    end

    private def self.catalog(io : IO, tags : Array(String), keys : Array(String), merged : Hash(String, Hash(String, Value))) : Nil
      entries = layout(keys, merged[tags[0]])
      io << "Punch::I18n::Catalog.new(\n" << tags.inspect << ",\n{\n"
      entries.each do |key, entry|
        io << key.inspect << " => Punch::I18n::Catalog::Entry.new(" << entry.slot << ", :" << entry.kind.to_s.downcase
        io << ", " << entry.size if entry.kind.list?
        io << "),\n"
      end
      io << "},\n[\n"
      tags.each do |tag|
        io << "# " << tag << "\n["
        texts(keys, merged[tag], entries).each { |text| io << text.inspect << ",\n" }
        io << "] of String?,\n"
      end
      io << "])\n"
    end

    private HEADER = "# Generated by `punch i18n:generate` from %s. Do not edit:\n# change the locale files and run `punch i18n:generate` again.\n\n"

    private def self.own_catalog(tags : Array(String), keys : Array(String), merged : Hash(String, Hash(String, Value))) : String
      String.build do |io|
        io << HEADER % "#{OWN_FILE}/*.yml"
        io << "module Punch::I18n\n# Punch's own messages and formats: the catalog of an app without\n# translations of its own.\nOWN = "
        catalog(io, tags, keys, merged)
        io << "end\n"
      end
    end

    private def self.accessors(type : String, default : String, tags : Array(String), keys : Array(String),
                               merged : Hash(String, Hash(String, Value)), directory : String) : String
      values = merged[default]
      entries = layout(keys, values)
      tree = Node.new
      keys.select { |key| accessor?(key) }.each do |key|
        *scopes, leaf = key.split('.')
        node = scopes.reduce(tree) { |parent, scope| parent.children[scope] ||= Node.new }
        node.leaves << {leaf, key}
      end
      String.build do |io|
        io << HEADER % "#{directory}/*.yml and Punch's own messages"
        io << "# The app's translations in one locale: `locale.t`, or `v.t` in a view.\n"
        io << "struct " << type << "\n"
        io << "DEFAULT = " << default.inspect << "\n\n"
        write_node(io, tree, values, entries)
        io << "\n# Every message of every locale, the default first.\nCATALOG = "
        catalog(io, tags, keys, merged)
        io << "end\n"
      end
    end

    private class Node
      getter children = {} of String => Node
      getter leaves = [] of {String, String}
    end

    private def self.write_node(io : IO, node : Node, values : Hash(String, Value), entries : Hash(String, I18n::Catalog::Entry)) : Nil
      io << "def initialize(@locale : Punch::Locale)\nend\n"
      node.leaves.each do |name, key|
        value, entry = values[key], entries[key]
        io << '\n'
        comment(io, value)
        names = value.names.to_a.sort!

        case value.kind
        in .message?
          if names.empty?
            io << "def " << name << " : String\n@locale.message(" << entry.slot << ")\nend\n"
          else
            io << "def " << name << "(*, " << names.join(", ") { |arg| "#{arg} : Punch::I18n::Arg" } << ") : String\n"
            io << "@locale.message(" << entry.slot << ", {" << names.join(", ") { |arg| "#{arg}: #{arg}" } << "})\nend\n"
          end
        in .plural?
          others = names - ["count"]
          io << "def " << name << "(*, count : Int" << others.join { |arg| ", #{arg} : Punch::I18n::Arg" } << ") : String\n"
          io << "@locale.plural(" << entry.slot << ", count, {" << (["count"] + others).join(", ") { |arg| "#{arg}: #{arg}" } << "})\nend\n"
        in .list?
          io << "def " << name << " : Array(String?)\n@locale.list(" << key.inspect << ")\nend\n"
        end
      end
      node.children.each do |scope, child|
        type = camelcase(scope)
        io << "\ndef " << scope << " : " << type << '\n' << type << ".new(@locale)\nend\n"
        io << "\nstruct " << type << '\n'
        write_node(io, child, values, entries)
        io << "end\n"
      end
    end

    private def self.comment(io : IO, value : Value) : Nil
      case value.kind
      in .message? then io << "# " << value.texts[0].inspect << '\n'
      in .plural?
        forms = Category.values.compact_map { |category| value.texts[category.value]?.try { |text| "#{category.to_s.downcase}: #{text.inspect}" } }
        io << "# " << forms.join(", ") << '\n'
      in .list? then io << "# " << value.texts.size << " items\n"
      end
    end

    # Error and problem codes the app's code can produce that have no
    # message in the default locale.
    private def self.codes(sources : Array(String), values : Hash(String, Value)) : Array(Finding)
      findings = [] of Finding
      seen = Set(String).new
      sources.each do |file|
        each_node(parse(File.read(file), file)) do |node|
          case node
          when Crystal::Call        then error_code(file, node, values, seen, findings)
          when Crystal::Expressions then problems(file, node, values, seen, findings)
          end
        end
      end
      findings.sort_by! { |finding| {finding.location.file, finding.location.line, finding.location.column || 0} }
    end

    # An error code (`Punch::Invalid.new` with a literal) without a message.
    private def self.error_code(file : String, node : Crystal::Call, values : Hash(String, Value), seen : Set(String), findings : Array(Finding)) : Nil
      return unless node.name == "new" && node.obj.to_s.in?("Invalid", "Punch::Invalid", "::Punch::Invalid")

      code = node.args[0]?.as?(Crystal::StringLiteral).try(&.value) || return
      key = "errors.#{code}"
      return if seen.includes?(key) || values.has_key?(key) || values.has_key?("punch.#{key}")

      seen << key
      findings << Finding.new(location(file, node), "the error code #{code} has no message: add #{key} to the locale files")
    end

    # The parser keeps a type's annotations as the expressions before it.
    private def self.problems(file : String, node : Crystal::Expressions, values : Hash(String, Value), seen : Set(String), findings : Array(Finding)) : Nil
      status = nil
      node.expressions.each do |expression|
        if expression.is_a?(Crystal::Annotation)
          status = expression if expression.path.to_s.in?("Punch::Status", "Status")
          next
        end
        problem(file, expression, status, values, seen, findings) if expression.is_a?(Crystal::ClassDef) && status
        status = nil
      end
    end

    private def self.problem(file : String, node : Crystal::ClassDef, status : Crystal::Annotation, values : Hash(String, Value),
                             seen : Set(String), findings : Array(Finding)) : Nil
      number = status.args[0]?.as?(Crystal::NumberLiteral).try(&.value.to_i) || return
      return if number < 400 || component?(node)

      code = node.name.names.last.underscore
      return if seen.includes?("problems.#{code}") || values.has_key?("problems.#{code}") || values.has_key?("punch.problems.#{code}")

      seen << "problems.#{code}"
      findings << Finding.new(location(file, node), "the problem #{code} (#{node.name}) has no message: add problems.#{code} to the locale files")
    end

    private def self.component?(node : Crystal::ClassDef) : Bool
      found = false
      each_node(node.body) do |child|
        found = true if child.is_a?(Crystal::Include) && child.name.to_s.ends_with?("Component")
      end
      found
    end

    # Accessor keys for which no call chain in *sources* ends the way
    # the key does: `t.invoices.sent`, or `t.sent` where the file assigns
    # `t = v.t.invoices`. A report, not a failure: a key reached another
    # way shows up here too.
    private def self.unused(sources : Array(String), keys : Array(String), values : Hash(String, Value)) : Array({String, Location})
      pairs = Set(String).new
      sources.each do |file|
        root = parse(File.read(file), file)
        # What each variable is assigned from: the last call of the chain.
        bound = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
        each_node(root) do |node|
          case node
          when Crystal::Assign
            target, value = node.target, node.value
            bound[target.name] << chain(value).last if target.is_a?(Crystal::Var) && !chain(value).empty?
          when Crystal::MultiAssign
            node.targets.zip?(node.values) do |target, value|
              last = value.try { |assigned| chain(assigned).last? }
              bound[target.name] << last if target.is_a?(Crystal::Var) && last
            end
          end
        end
        each_node(root) do |node|
          next unless node.is_a?(Crystal::Call)
          names = chain(node)
          heads = bound[names.first]? || Set{names.first}
          heads.each do |head|
            ([head] + names[1..]).each_cons_pair { |first, second| pairs << "#{first}.#{second}" }
          end
          names.each_cons_pair { |first, second| pairs << "#{first}.#{second}" }
        end
      end
      keys.select { |key| accessor?(key) }.compact_map do |key|
        segments = ["t"] + key.split('.')
        {key, values[key].location} unless pairs.includes?(segments.last(2).join('.'))
      end
    end

    # The names of a call chain from its receiver: `v.t.invoices.sent`
    # is `v t invoices sent`; empty for anything but a call.
    private def self.chain(node : Crystal::ASTNode) : Array(String)
      names = [] of String
      current = node
      while current.is_a?(Crystal::Call)
        names.unshift(current.name)
        current = current.obj || break
      end
      names.unshift(current.name) if current.is_a?(Crystal::Var) && !names.empty?
      names
    end

    private def self.parse(source : String, file : String) : Crystal::ASTNode
      Crystal::Parser.parse(source)
    rescue ex : Crystal::SyntaxException
      raise QueryGen::Errors.new([Error.new(Location.new(file, ex.line_number, ex.column_number), ex.message || "does not parse")])
    end

    private def self.location(file : String, node : Crystal::ASTNode) : Location
      Location.new(file, node.location.try(&.line_number) || 1, node.location.try(&.column_number))
    end

    private def self.each_call(node : Crystal::ASTNode, &block : Crystal::Call ->) : Nil
      each_node(node) { |child| block.call(child) if child.is_a?(Crystal::Call) }
    end

    private def self.each_node(node : Crystal::ASTNode, &block : Crystal::ASTNode ->) : Nil
      visitor = Visitor.new(block)
      node.accept(visitor)
    end

    private class Visitor < Crystal::Visitor
      def initialize(@block : Crystal::ASTNode ->)
      end

      def visit(node : Crystal::ASTNode) : Bool
        @block.call(node)
        true
      end
    end
  end
end
