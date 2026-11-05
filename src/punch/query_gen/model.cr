module Punch::QueryGen
  # A place in a source file, for error messages: `file:line:column`.
  record Location, file : String, line : Int32, column : Int32? = nil do
    def to_s(io : IO) : Nil
      io << file << ':' << line
      io << ':' << column if column
    end
  end

  # A mistake in the schema, the mapping file, or a query file. The
  # generator collects all of them before it reports, and writes nothing.
  class Error < Exception
    getter location : Location

    def initialize(@location : Location, message : String)
      super(message)
    end

    def to_s(io : IO) : Nil
      io << location << ": " << message
    end
  end

  # Raised with every error of one run.
  class Errors < Exception
    getter errors : Array(Error)

    def initialize(@errors : Array(Error))
      super(errors.join('\n', &.to_s))
    end
  end

  # The type of a column or parameter: how it is stored, the domain type it
  # maps to if any, and whether it can be `NULL`. An encrypted column
  # (`Punch::Encrypted(T)`) also names itself, `table.column`, since its key
  # is derived from that name; its values are `Punch::Secret(T)`. A blind
  # index (`Punch::BlindIndex.of(:column)`) names itself in *blind* the same
  # way; its domain is the encrypted column's `T`, which parameters compared
  # with it take, and *lookup* marks such a parameter, which binds the
  # hashes under every key.
  #
  # While a plaintext column is converted
  # (`Punch::Encrypted(T).from(:email)`), the encrypted column's type names
  # the plaintext column in *from*, and the plaintext column's names the
  # encrypted one in *plaintext_of*.
  #
  # An *array* parameter (`id IN carray(:ids)`) binds an `Array` of the
  # type; it is never `NULL`, nor are its elements.
  record Type, stored : String, domain : String? = nil, nullable : Bool = false, encrypted : String? = nil,
    blind : String? = nil, lookup : Bool = false, from : String? = nil, plaintext_of : String? = nil, filled : Bool = false,
    array : Bool = false do
    # The Crystal type of the value. A column converted from a NOT NULL
    # plaintext column is *filled*: its value is never NULL, read from
    # either column, though the column itself still can be.
    def crystal : String
      return "Array(#{value_type})" if array

      nullable && !filled ? "#{value_type}?" : value_type
    end

    private def value_type : String
      inner = domain
      if encrypted && inner
        "Punch::Secret(#{inner.lchop("Punch::Encrypted(").rchop(")")})"
      else
        inner || stored
      end
    end

    def stored_crystal : String
      nullable ? "#{stored}?" : stored
    end

    def nilable(flag : Bool = true) : Type
      copy_with(nullable: flag)
    end

    # The same value without its domain type: after arithmetic, `sum`,
    # or string functions, a value is no longer an ID or an email.
    def bare : Type
      copy_with(domain: nil, encrypted: nil, blind: nil, lookup: false, from: nil, plaintext_of: nil, filled: false, array: false)
    end

    # The type of an expression over this value: an encrypted value outside
    # its own column is ciphertext, `Bytes`, since only the column's name
    # gives its key; a blind index is a hash.
    def derived : Type
      encrypted || blind ? bare : self
    end

    # The encrypted or blind index column this value is stored in, if any.
    def secret_column : String?
      encrypted || blind
    end
  end

  STORED_TYPES = %w[Int64 Float64 String Bytes]

  # Domain types whose stored form the generator knows. Every other domain
  # type's stored form is checked by the compiler (`Punch::Stored.load`).
  BUILTIN_DOMAINS = {"Time" => "String", "Bool" => "Int64"}

  # The stored Crystal type for a declared column type, by SQLite's type
  # affinity rules; `nil` for `ANY` and for no declared type.
  def self.stored_type(declared : String?) : String?
    upper = declared.try(&.upcase) || return
    return "Int64" if upper.includes?("INT")
    return "String" if upper.includes?("CHAR") || upper.includes?("CLOB") || upper.includes?("TEXT")
    return "Bytes" if upper.includes?("BLOB")
    return "Float64" if upper.includes?("REAL") || upper.includes?("FLOA") || upper.includes?("DOUB")

    nil
  end

  # Parses a type written in an annotation: a stored type, `Bool`, or
  # `Time`, optionally nilable (`String?`).
  def self.annotation_type(text : String) : Type?
    name = text.strip
    nullable = name.ends_with?('?')
    name = name.rchop('?')
    if STORED_TYPES.includes?(name)
      Type.new(name, nil, nullable)
    elsif stored = BUILTIN_DOMAINS[name]?
      Type.new(stored, name, nullable)
    end
  end

  KEYWORDS = %w[abstract alias annotation as asm begin break case class def do else elsif end ensure enum extend false
    for fun if in include instance_sizeof is_a? lib macro module next nil nil? of offsetof out pointerof private protected
    require rescue responds_to? return select self sizeof struct super then true type typeof uninitialized union unless
    until verbatim when while with yield]

  # Whether *name* can be a Crystal getter and named argument.
  def self.identifier?(name : String) : Bool
    name.matches?(/\A[a-z_][a-z0-9_]*\z/) && !KEYWORDS.includes?(name)
  end

  def self.camelcase(name : String) : String
    name.split('_').join(&.capitalize)
  end

  def self.underscore(name : String) : String
    name.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2").downcase
  end
end
