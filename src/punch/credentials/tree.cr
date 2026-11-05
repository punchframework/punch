require "yaml"

module Punch::Credentials
  # The decrypted YAML as plain text values: every scalar stays the string
  # it was written as, so `no` is not `false`, `2026-10-09` is not a date,
  # and `0755` is not a number until a field's type parses it.
  alias Tree = String | Hash(String, Tree) | Array(Tree)?

  module YAMLTree
    NULLS = {"", "~", "null", "Null", "NULL"}

    # The mapping at the root of *text*, or a problem. An empty document,
    # or one with only comments, is an empty mapping.
    def self.parse(text : String, file : String) : Hash(String, Tree) | String
      root = YAML::Nodes.parse(text).nodes.first? || return {} of String => Tree

      case tree = convert(root, file)
      in Hash(String, Tree) then tree
      in Nil                then {} of String => Tree
      in String, Array(Tree)
        "#{file} must hold a YAML mapping at the top"
      end
    rescue ex : YAML::ParseException
      "#{file} is not valid YAML: #{ex.message}"
    rescue ex : Problem
      ex.message || "#{file} is not valid"
    end

    private class Problem < Exception
    end

    private def self.convert(node : YAML::Nodes::Node, file : String) : Tree
      case node
      when YAML::Nodes::Scalar
        node.style.plain? && NULLS.includes?(node.value) ? nil : node.value
      when YAML::Nodes::Sequence
        node.nodes.map { |item| convert(item, file) }
      when YAML::Nodes::Mapping
        hash = {} of String => Tree
        node.nodes.each_slice(2) do |(key, value)|
          name = key.as?(YAML::Nodes::Scalar).try(&.value)
          raise Problem.new("#{file}, line #{key.start_line + 1}: keys must be plain names") unless name
          raise Problem.new("#{file}, line #{key.start_line + 1}: '#{name}' appears twice") if hash.has_key?(name)
          hash[name] = convert(value, file)
        end
        hash
      else
        raise Problem.new("#{file}, line #{node.start_line + 1}: anchors and aliases are not supported")
      end
    end

    # YAML for *tree*. Strings that would read back as null are quoted;
    # comments are not kept.
    def self.dump(tree : Hash(String, Tree)) : String
      YAML.build { |yaml| emit(yaml, tree) }
    end

    private def self.emit(yaml : YAML::Builder, tree : Tree) : Nil
      case tree
      in Nil then yaml.scalar("", style: YAML::ScalarStyle::PLAIN)
      in String
        style = if NULLS.includes?(tree)
                  YAML::ScalarStyle::DOUBLE_QUOTED
                elsif tree.includes?('\n')
                  YAML::ScalarStyle::LITERAL
                else
                  YAML::ScalarStyle::ANY
                end
        yaml.scalar(tree, style: style)
      in Array(Tree)
        yaml.sequence { tree.each { |item| emit(yaml, item) } }
      in Hash(String, Tree)
        yaml.mapping { tree.each { |key, value| yaml.scalar(key); emit(yaml, value) } }
      end
    end
  end
end
