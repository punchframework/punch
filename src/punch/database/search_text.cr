module Punch
  class Database
    # Makes user text match itself in a `LIKE` pattern built around it in
    # SQL: `\`, `%`, and `_` get a `\` in front, which the query's
    # `ESCAPE '\'` undoes. The value is still bound as a parameter; this
    # changes what it matches, not the statement.
    #
    # ```sql
    # -- when q: AND name LIKE '%' || :q || '%' ESCAPE '\'
    # ```
    #
    # ```
    # Queries.page(db, filter: Queries::Page::Filter.new(q: Punch::Database.escape_like(input.q)))
    # Punch::Database.escape_like("50%_off") # => "50\\%\\_off"
    # ```
    def self.escape_like(text : String) : String
      return text unless text.each_char.any?(&.in?('\\', '%', '_'))

      String.build(text.bytesize + 8) do |io|
        text.each_char do |char|
          io << '\\' if char.in?('\\', '%', '_')
          io << char
        end
      end
    end

    # User text as one FTS5 phrase, for `MATCH :q`: in double quotes, with
    # double quotes inside doubled, so `AND`, `OR`, `NOT`, `*`, `^`, `:`, and
    # parentheses are words, not search syntax. A screen that offers the
    # syntax on purpose binds the text as it is.
    #
    # ```
    # Punch::Database.fts_phrase(%(say "hi" OR x)) # => %("say ""hi"" OR x")
    # ```
    def self.fts_phrase(text : String) : String
      %("#{text.gsub('"', %(""))}")
    end
  end
end
