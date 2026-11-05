module Bareknuckle
  # The app's source files as the build of a round read them, by absolute
  # path. The compiler reads required files through `read` (`hooks.cr`),
  # so the daemon types exactly what `punch dev` built, even when a file
  # was saved again since; files outside the app (the standard library,
  # shards) are read from disk.
  module Sources
    # The app's root directory, absolute, with a trailing slash. Its `lib/`
    # (the shards) is not the app.
    class_property root = ""
    # What the next typing reads instead of the disk.
    class_property overlay = {} of String => String
    # The app's files the last typing read, with their contents.
    class_getter read = {} of String => String

    def self.read(filename : String) : String
      content = overlay[filename]? || File.read(filename)
      @@read[filename] = content if filename.starts_with?(root) && !filename.starts_with?("#{root}lib/")
      content
    end
  end

  # What macros read while typing, by absolute path, and the commands they
  # ran (`run`, `system`): an edit of one of those files can change any
  # macro's output, so it needs a full build.
  module MacroReads
    class_getter files = Set(String).new
    class_getter commands = Set(String).new

    def self.file(path : String) : Nil
      @@files << File.expand_path(path)
    end

    def self.command(command : String) : Nil
      @@commands << command
    end

    def self.clear : Nil
      @@files.clear
      @@commands.clear
    end
  end
end
