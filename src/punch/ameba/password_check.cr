module Ameba::Rule::Punch
  # Keeps sign-ins on the checked path (docs/auth.md): a password is
  # checked through a Command whose `call` takes
  # `Punch::Auth::PasswordCheck` or `OwnPasswordCheck`. The compiler then
  # requires the rate limit by address or by actor, and the router hashes
  # on the hasher before the transaction, so one writer is never held for
  # the hashing. Outside Punch's own code this reports the functions underneath, which skip both: `verify_now` and
  # `hash_now` on any receiver, and `Passwords.hasher`, `Passwords.lookup`,
  # and `Passwords.stored`. A new password is hashed by
  # `Punch::Auth::NewPassword`.
  #
  # ```
  # Punch/PasswordCheck:
  #   Enabled: true
  # ```
  class PasswordCheck < Base
    properties do
      since_version "1.7.0"
      description "Reports checking or hashing a password outside PasswordCheck"
    end

    MSG = "Check a password by taking `password : Punch::Auth::PasswordCheck` (or `OwnPasswordCheck`) in the Command's `call`: the compiler then requires the rate limit, and the hashing runs before the transaction (lib/punch/docs/auth.md)"

    # Methods reported on any receiver.
    ANYWHERE = %w[verify_now hash_now]
    # Methods reported on `Passwords`.
    PASSWORDS = %w[hasher lookup stored]

    def test(source : Source)
      return if punch?(source.path)

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.calls.each { |node| issue_for node, MSG }
    end

    # Punch's own code, which builds these paths.
    private def punch?(path : String) : Bool
      path.starts_with?("src/punch/") || path.includes?("/src/punch/")
    end

    private class Finder < Crystal::Visitor
      getter calls = [] of Crystal::Call

      def visit(node : Crystal::Call)
        receiver = node.obj
        if node.name.in?(ANYWHERE) && receiver
          calls << node
        elsif node.name.in?(PASSWORDS) && receiver.is_a?(Crystal::Path) && receiver.names.last == "Passwords"
          calls << node
        end
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
