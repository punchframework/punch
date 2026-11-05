# The parts of Crystal's compiler bareknuckle uses: parsing, the semantic
# pass, and what macros need (macro `run` compiles and links a program).
# Not `compiler/requires`: the command line it pulls in needs the
# documentation generator's shards, which a Crystal install does not have.

# `Crystal::Command::Exit`, which the compiler's errors refer to, without
# the command line that defines it; its values are the compiler's.
class Crystal::Command
  enum Exit
    OK             = 0
    FAILURE        = 1
    USAGE_ERROR    = 1 # ameba:disable Lint/DuplicateEnumValue
    CODE_ERROR     = 1 # ameba:disable Lint/DuplicateEnumValue
    SOFTWARE_ERROR = 1 # ameba:disable Lint/DuplicateEnumValue
  end
end

require "compiler/crystal/annotatable"
require "compiler/crystal/program"
require "compiler/crystal/compiler"
require "compiler/crystal/config"
require "compiler/crystal/crystal_path"
require "compiler/crystal/error"
require "compiler/crystal/exception"
require "compiler/crystal/macros"
require "compiler/crystal/progress_tracker"
require "compiler/crystal/semantic"
require "compiler/crystal/syntax"
require "compiler/crystal/types"
require "compiler/crystal/util"
require "compiler/crystal/warnings"
require "compiler/crystal/tools/dependencies"
require "compiler/crystal/tools/formatter"
require "compiler/crystal/semantic/*"
require "compiler/crystal/macros/*"
require "compiler/crystal/codegen/*"
