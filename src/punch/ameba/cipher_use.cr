module Ameba::Rule::Punch
  # Keeps encryption in `Punch::Crypto`: `OpenSSL::Cipher` appears only
  # under `src/punch/crypto/`, where the tag length is fixed (`gcm_tag=`
  # accepts truncated tags) and every key is derived for one purpose.
  # Everything else seals and opens through `Punch::Crypto` or the formats
  # built on it.
  #
  # ```
  # Punch/CipherUse:
  #   Enabled: true
  # ```
  class CipherUse < Base
    properties do
      since_version "1.7.0"
      description "Reports OpenSSL::Cipher outside Punch::Crypto"
    end

    MSG = "`OpenSSL::Cipher` is used only inside Punch::Crypto, which fixes the tag length and derives a key per purpose (lib/punch/docs/keys.md)"

    def test(source : Source)
      return if source.path.includes?("src/punch/crypto/")

      visitor = Finder.new
      source.ast.accept(visitor)
      visitor.paths.each { |node| issue_for node, MSG }
    end

    private class Finder < Crystal::Visitor
      getter paths = [] of Crystal::Path

      def visit(node : Crystal::Path)
        names = node.names
        paths << node if names.size >= 2 && names[0] == "OpenSSL" && names[1] == "Cipher"
        true
      end

      def visit(node : Crystal::ASTNode)
        true
      end
    end
  end
end
