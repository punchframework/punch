require "../spec_helper"

# Punch's top-level type names, without those the standard library already
# declares at the top level (`HTTP`, `Crypto`, `Spec`): an app module of
# that name would reopen the standard library's.
PUNCH_TOP_LEVEL = {{ Punch.constants.select { |name| Punch.constant(name).is_a?(TypeNode) && !@top_level.has_constant?(name.stringify) }.map(&.stringify).sort }}

# The reference app's top-level modules and the names of Punch's they get.
APP_RENAMES = {"Accounts" => "Auth", "Billing" => "Mailer", "Invoicing" => "Events"}

# An app's top-level modules may be named like Punch's: every type name
# Punch's macros write is global (`Punch::NAME_STARTS`). The reference app
# is the kitchen sink, so a copy of it with its top-level modules renamed to
# Punch's names, plus one operation under each other top-level name of
# Punch's, has to type-check.
describe "app modules named like Punch's" do
  it "type-checks the reference app under Punch's names" do
    root = Path[__DIR__, "..", ".."].expand
    copy = Path[Dir.tempdir, "punch-app-names-#{Random::Secure.hex(4)}"]
    begin
      Dir.mkdir_p(copy / "lib")
      %w[app src config db].each { |dir| copy_tree(root / "reference" / dir, copy / dir) }
      File.symlink(root, copy / "lib" / "punch")
      Dir.each_child(root / "lib") { |shard| File.symlink(root / "lib" / shard, copy / "lib" / shard) }

      Dir.glob("#{copy}/{app,src}/**/*.cr").each do |file|
        source = File.read(file)
        renamed = APP_RENAMES.reduce(source) { |text, (from, to)| text.gsub(/\b#{from}\b/, to) }
        File.write(file, renamed) unless renamed == source
      end
      File.write(copy / "app" / "names.cr", one_operation_per_name(PUNCH_TOP_LEVEL - APP_RENAMES.values))
      File.open(copy / "src" / "invoicing.cr", "a", &.puts(%(require "../app/names")))

      output = IO::Memory.new
      status = Process.run("crystal", ["build", "--no-codegen", "--no-color", "src/main.cr"],
        chdir: copy.to_s, output: output, error: output)
      fail "the renamed reference app does not compile:\n#{output}" unless status.success?
    ensure
      FileUtils.rm_rf(copy)
    end
  end

  it "covers Punch's own top-level names" do
    PUNCH_TOP_LEVEL.should contain("Mailer")
    PUNCH_TOP_LEVEL.should contain("Auth")
    PUNCH_TOP_LEVEL.should_not contain("HTTP")
  end
end

private def copy_tree(from : Path, to : Path) : Nil
  Dir.mkdir_p(to)
  Dir.each_child(from) do |child|
    if File.directory?(from / child)
      copy_tree(from / child, to / child)
    else
      File.copy(from / child, to / child)
    end
  end
end

private def one_operation_per_name(names : Array(String)) : String
  String.build do |io|
    names.each do |name|
      io << <<-CRYSTAL
        module #{name}
          struct Pong
            include JSON::Serializable

            def initialize
            end
          end

          @[Punch::Public]
          struct Ping < Punch::Query
            struct Input
              include Punch::Input
            end

            def call(input : Input, db : Punch::Reader) : Pong
              Pong.new
            end
          end
        end


        CRYSTAL
    end
  end
end
