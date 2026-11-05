require "json"

module Punch::OpenAPI
  # Breaking changes between two OpenAPI documents, for CI. A change breaks
  # a client that was correct against the old document:
  #
  # - an operation, or a success response of one, is gone;
  # - a request needs something new: a new required parameter or property,
  #   a request body that became required, a type or enum value no longer
  #   accepted;
  # - a response promises less: a property gone or no longer always
  #   present, a new type, or a new enum value a client may not handle.
  #
  # Adding operations, optional inputs, response properties, or accepted
  # values is not breaking. Schemas are compared through their `$ref`s.
  class Diff
    getter changes = [] of String

    def initialize(@old : JSON::Any, @new : JSON::Any)
      @seen = Set({String, String, Bool}).new
      compare_paths
    end

    def self.breaking(old : JSON::Any, new : JSON::Any) : Array(String)
      new(old, new).changes
    end

    private def compare_paths : Nil
      old_paths = @old["paths"]?.try(&.as_h?) || {} of String => JSON::Any
      new_paths = @new["paths"]?.try(&.as_h?) || {} of String => JSON::Any
      old_paths.each do |path, methods|
        methods.as_h.each do |method, operation|
          where = "#{method.upcase} #{path}"
          if counterpart = new_paths[path]?.try(&.[method]?)
            compare_operation(where, operation, counterpart)
          else
            @changes << "#{where}: the operation was removed"
          end
        end
      end
    end

    private def compare_operation(where : String, old : JSON::Any, new : JSON::Any) : Nil
      old_parameters = parameters(old)
      parameters(new).each do |key, parameter|
        previous = old_parameters[key]?
        if previous.nil? && parameter["required"]? == true
          @changes << "#{where}: new required #{key[0]} parameter #{key[1]}"
        elsif previous && parameter["required"]? == true && previous["required"]? != true
          @changes << "#{where}: #{key[0]} parameter #{key[1]} became required"
        end
        start(previous["schema"], parameter["schema"], "#{where}: #{key[0]} parameter #{key[1]}", request: true) if previous
      end
      compare_body(where, old["requestBody"]?, new["requestBody"]?)
      compare_responses(where, old["responses"]?.try(&.as_h?), new["responses"]?.try(&.as_h?))
    end

    private def parameters(operation : JSON::Any) : Hash({String, String}, JSON::Any)
      list = operation["parameters"]?.try(&.as_a?) || [] of JSON::Any
      list.to_h { |parameter| { {parameter["in"].as_s, parameter["name"].as_s}, parameter } }
    end

    private def compare_body(where : String, old : JSON::Any?, new : JSON::Any?) : Nil
      return unless new

      if new["required"]? == true && old.try(&.["required"]?) != true
        @changes << "#{where}: the request body became required"
      end
      old_schema = old.try(&.dig?("content", "application/json", "schema"))
      new_schema = new.dig?("content", "application/json", "schema")
      start(old_schema, new_schema, "#{where}: request body", request: true) if old_schema && new_schema
    end

    private def compare_responses(where : String, old : Hash(String, JSON::Any)?, new : Hash(String, JSON::Any)?) : Nil
      return unless old && new

      old.each do |status, response|
        counterpart = new[status]?
        unless counterpart
          @changes << "#{where}: response #{status} was removed" if status.starts_with?('2')
          next
        end
        response["content"]?.try(&.as_h?).try &.each do |media_type, content|
          old_schema = content["schema"]?
          new_schema = counterpart.dig?("content", media_type, "schema")
          start(old_schema, new_schema, "#{where}: response #{status}", request: false) if old_schema && new_schema
        end
      end
    end

    # One comparison of a parameter, body, or response. The guard against
    # recursive schemas covers only this comparison, so a changed component
    # is reported at every operation that uses it.
    private def start(old : JSON::Any, new : JSON::Any, where : String, *, request : Bool) : Nil
      @seen.clear
      compare(old, new, where, request: request)
    end

    # Compares two schemas in the direction data flows: a request schema
    # may only accept more, a response schema may only promise more.
    private def compare(old : JSON::Any, new : JSON::Any, where : String, *, request : Bool) : Nil
      return unless @seen.add?({old.to_json, new.to_json, request})

      old, new = resolve(@old, old), resolve(@new, new)
      compare_types(old, new, where, request)
      compare_enums(old, new, where, request)
      compare_properties(old, new, where, request)
      if (old_items = old["items"]?) && (new_items = new["items"]?)
        compare(old_items, new_items, "#{where} items", request: request)
      end
      {"allOf", "anyOf", "oneOf"}.each do |keyword|
        old_parts, new_parts = old[keyword]?.try(&.as_a?), new[keyword]?.try(&.as_a?)
        next unless old_parts && new_parts && old_parts.size == new_parts.size

        # The order of the parts means nothing: an unchanged part may move.
        # The ones that changed are compared in the order they stand.
        old_changed = old_parts.reject { |part| new_parts.any? { |other| same?(part, other) } }
        new_changed = new_parts.reject { |part| old_parts.any? { |other| same?(other, part) } }
        next unless old_changed.size == new_changed.size

        old_changed.zip(new_changed) { |old_part, new_part| compare(old_part, new_part, where, request: request) }
      end
    end

    # Whether a part of the old document and one of the new say the same,
    # their references followed.
    private def same?(old : JSON::Any, new : JSON::Any) : Bool
      resolve(@old, old).to_json == resolve(@new, new).to_json
    end

    private def compare_types(old : JSON::Any, new : JSON::Any, where : String, request : Bool) : Nil
      old_types, new_types = types(old), types(new)
      return if old_types.empty? || new_types.empty?

      if request && !(lost = old_types - new_types).empty?
        @changes << "#{where} no longer accepts #{lost.join(", ")}"
      elsif !request && !(gained = new_types - old_types).empty?
        @changes << "#{where} may now be #{gained.join(", ")}"
      end
    end

    private def compare_enums(old : JSON::Any, new : JSON::Any, where : String, request : Bool) : Nil
      old_values, new_values = old["enum"]?.try(&.as_a?), new["enum"]?.try(&.as_a?)
      if request && old_values && new_values && !(lost = old_values - new_values).empty?
        @changes << "#{where} no longer accepts #{lost.map(&.to_json).join(", ")}"
      elsif !request && new_values && (!old_values || !(gained = new_values - old_values).empty?)
        @changes << "#{where} may now be #{(gained || new_values).map(&.to_json).join(", ")}"
      end
    end

    private def compare_properties(old : JSON::Any, new : JSON::Any, where : String, request : Bool) : Nil
      old_properties = old["properties"]?.try(&.as_h?) || return
      new_properties = new["properties"]?.try(&.as_h?) || return
      old_required, new_required = required(old), required(new)
      if request
        (new_required - old_required).each { |name| @changes << "#{where}: new required property #{name}" }
      else
        old_properties.each_key do |name|
          if !new_properties.has_key?(name)
            @changes << "#{where}: property #{name} was removed"
          elsif old_required.includes?(name) && !new_required.includes?(name)
            @changes << "#{where}: property #{name} is no longer always present"
          end
        end
      end
      old_properties.each do |name, schema|
        counterpart = new_properties[name]? || next
        compare(schema, counterpart, "#{where}.#{name}", request: request)
      end
    end

    private def types(schema : JSON::Any) : Array(String)
      case type = schema["type"]?
      when Nil then [] of String
      else          type.as_a?.try(&.map(&.as_s)) || [type.as_s]
      end
    end

    private def required(schema : JSON::Any) : Array(String)
      schema["required"]?.try(&.as_a.map(&.as_s)) || [] of String
    end

    # Follows `$ref`s within *document*, so a renamed component is compared
    # by content. Siblings of `$ref` (such as `default`) are kept.
    private def resolve(document : JSON::Any, schema : JSON::Any) : JSON::Any
      10.times do
        reference = schema["$ref"]?.try(&.as_s?) || return schema
        target = reference.lchop("#/").split('/').reduce(document) { |node, key| node[key]? || return schema }
        rest = schema.as_h.reject("$ref")
        schema = rest.empty? ? target : JSON::Any.new(target.as_h.merge(rest))
      end
      schema
    end
  end
end
