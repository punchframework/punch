module Punch::Spec
  # Loads the credentials type *type* from *yaml*, written as the decrypted
  # file would hold it, and from *env* in place of the environment; makes
  # it `current` (with its key ring, if it has one) and returns it. Fails the example with every problem.
  #
  # ```
  # Punch::Spec.credentials(Invoicing::Credentials, <<-YAML)
  #   issuer:
  #     name: Example GmbH
  #   YAML
  # ```
  def self.credentials(type : T.class, yaml : String = "", env : Hash(String, String) = {} of String => String,
                       file = __FILE__, line = __LINE__) : T forall T
    origin = "the credentials of #{file}:#{line}"
    tree = Credentials::YAMLTree.parse(yaml, origin)
    fail(tree, file, line) if tree.is_a?(String)
    source = Credentials::Source.new("test", ->(name : String) { env[name]?.presence }, tree, origin)
    Credentials.loaded = source
    case value = T.load(source)
    in T
      Credentials.install(value).tap do
        fail("#{T} does not load:\n  #{Mailer.problems.join("\n  ")}", file, line) unless Mailer.problems.empty?
        fail("#{T} does not load:\n  #{Upload.settings_problems.join("\n  ")}", file, line) unless Upload.settings_problems.empty?
      end
    in Array(String) then fail("#{T} does not load:\n  #{value.join("\n  ")}", file, line)
    end
  end
end
