require "json"

module Punch::Payloads
  # The payload lock file, `payloads.lock.json`: the schema of every stored
  # payload, so `punch check` notices a change that a binary on either side
  # of a deploy cannot read. Compared here, in the `punch` tool; derived by
  # the app's derivation build (`jobs:derive`).
  #
  # A payload written by one binary is read by another: old payloads by
  # new code after a deploy, new payloads by old code after a rollback or
  # during a handover. Between two schemas of one version:
  #
  # - a field the new reader requires must be one the old writer always
  #   wrote (a new required field, or a nilable one made required, breaks);
  # - a field the old reader requires must be one the new writer always
  #   writes (removing it, or making it nilable, breaks);
  # - a field both know keeps its type, down to enum members; objects
  #   inside follow the same rules.
  #
  # Adding a nilable or defaulted field and removing an optional one are
  # compatible: readers ignore fields they do not know. Anything else needs
  # a new version with the old shape kept as a frozen type, whose schema
  # must match what the lock recorded for that version.
  class Lock
    FILE = "payloads.lock.json"

    # How to get out of a breaking change, said once after the list.
    WAYS_OUT = "Either keep the change compatible (new fields nilable or with a default; keep every field older binaries require, with its type), " \
               "or raise the payload version: @[Punch::Payloads::Version(N, from: {N - 1 => V1})], with the old shape kept as a frozen type " \
               "that upgrades itself (lib/punch/docs/jobs.md)."

    getter problems = [] of String
    getter notes = [] of String

    # Problems about steps of jobs with steps, which carry their own way
    # out; the rest are about payload schemas.
    @step_problems = 0

    # What to say after the problems: how out of a payload change, or
    # nothing when only steps changed (their problems say how).
    def ways_out : String
      @problems.size > @step_problems ? "\n#{WAYS_OUT}" : ""
    end

    # Compares the *derived* lock with the committed *lock* (`nil` when
    # there is none yet). *drop* lists stored job types whose removal is
    # acknowledged; with *removals*, every removal is (a comparison with an
    # older lock, whose drops were acknowledged when it was written).
    def initialize(@lock : JSON::Any?, @derived : JSON::Any, drop : Array(String) = [] of String, *, removals : Bool = false)
      @drop = drop
      @removals = removals
      compare
    end

    def ok? : Bool
      @problems.empty?
    end

    private def compare : Nil
      old_payloads = section(@lock, "payloads")
      new_payloads = section(@derived, "payloads")
      new_payloads.each do |name, payload|
        if previous = old_payloads[name]?
          compare_payload(name, previous, payload)
        else
          steps = payload["steps"]?.try(&.as_a?).try { |list| ", in steps: #{list.map(&.["name"].as_s).join(", ")}" }
          @notes << "#{name}: new payload, version #{payload["version"]}#{steps}"
        end
      end
      compare_documents
      old_types = section(@lock, "types")
      new_types = section(@derived, "types")
      old_types.each_key do |type|
        next if new_types.has_key?(type)
        if @removals || @drop.includes?(type)
          @notes << "#{type}: removed"
        else
          @problems << "#{type} is gone, but jobs of it may still wait in queue.db, where nothing would run them. " \
                       "Once `punch jobs:versions` shows none in every environment, acknowledge it: punch jobs:lock --drop '#{type}'"
        end
      end
    end

    private def compare_payload(name : String, old : JSON::Any, new : JSON::Any) : Nil
      old_version, new_version = old["version"].as_i, new["version"].as_i
      new_frozen = new["frozen"]?.try(&.as_h) || {} of String => JSON::Any
      old_frozen = old["frozen"]?.try(&.as_h) || {} of String => JSON::Any
      if new_version < old_version
        @problems << "#{name}: the payload version went down from #{old_version} to #{new_version}; jobs of version #{old_version} may be waiting"
      elsif new_version == old_version
        breaking = Lock.changes(old["schema"], new["schema"], name)
        @problems.concat(breaking)
        @notes << "#{name}: compatible change" if breaking.empty? && Lock.canonical(old["schema"]) != Lock.canonical(new["schema"])
      elsif frozen = new_frozen[old_version.to_s]?
        @problems.concat(Lock.changes(old["schema"], frozen, "#{name} version #{old_version} (frozen type)"))
        @notes << "#{name}: version #{old_version} to #{new_version}"
      else
        @problems << "#{name}: version #{old_version} payloads may still be waiting, but nothing reads them now: " \
                     "keep their shape as a frozen type, from: {#{old_version} => V#{old_version}} (lib/punch/docs/jobs.md)"
      end
      compare_steps(name, old["steps"]?.try(&.as_a?), new["steps"]?.try(&.as_a?))
      old_frozen.each do |version, schema|
        if counterpart = new_frozen[version]?
          unless Lock.canonical(schema) == Lock.canonical(counterpart)
            @problems << "#{name}: the frozen type of version #{version} changed; a frozen type keeps the shape its version was written with"
          end
        else
          @notes << "#{name}: the frozen type of version #{version} was removed; payloads of that version are parked"
        end
      end
    end

    # How to get out of a breaking change to a composite's document.
    DOCUMENT_WAYS_OUT = "keep the change compatible (new fields nilable or with a default; keep every field older binaries require, with its type), " \
                        "or raise the composite's version: version: N, from: {N - 1 => V1}, with the old shape kept as a frozen type that upgrades itself " \
                        "(lib/punch/docs/composites.md)"

    # Composites stored as JSON documents (docs/composites.md, "Versions"):
    # a document written by one release is read by the next, and by the one
    # before after a rollback, under the same rules as payloads. Rows of an
    # old version stay until `punch db:upgrade` rewrites them, so removing
    # a frozen type, or a composite, is a note: `db:audit` says whether
    # rows of it are left.
    private def compare_documents : Nil
      old_documents = section(@lock, "documents")
      section(@derived, "documents").each do |name, document|
        unless previous = old_documents[name]?
          @notes << "#{name}: new document, version #{document["version"]}"
          next
        end
        compare_document(name, previous, document)
      end
      old_documents.each_key do |name|
        @notes << "#{name}: no longer stored as a document; rows that hold it are no longer read" unless section(@derived, "documents").has_key?(name)
      end
    end

    private def compare_document(name : String, old : JSON::Any, new : JSON::Any) : Nil
      old_version, new_version = old["version"].as_i, new["version"].as_i
      new_frozen = new["frozen"]?.try(&.as_h) || {} of String => JSON::Any
      old_frozen = old["frozen"]?.try(&.as_h) || {} of String => JSON::Any
      problems = if new_version < old_version
                   ["#{name}: the version went down from #{old_version} to #{new_version}; rows of version #{old_version} may be stored"]
                 elsif new_version == old_version
                   Lock.changes(old["schema"], new["schema"], name).map(&.sub("payloads written before", "documents written before"))
                 elsif frozen = new_frozen[old_version.to_s]?
                   @notes << "#{name}: version #{old_version} to #{new_version}"
                   Lock.changes(old["schema"], frozen, "#{name} version #{old_version} (frozen type)")
                 else
                   ["#{name}: rows of version #{old_version} may be stored, but nothing reads them now: keep their shape as a frozen type, from: {#{old_version} => V#{old_version}}"]
                 end
      old_frozen.each do |version, schema|
        if counterpart = new_frozen[version]?
          problems << "#{name}: the frozen type of version #{version} changed; a frozen type keeps the shape its version was written with" unless Lock.canonical(schema) == Lock.canonical(counterpart)
        else
          @notes << "#{name}: the frozen type of version #{version} was removed; rows still of that version no longer read (check punch db:audit)"
        end
      end
      @step_problems += problems.size
      @problems.concat(problems.map { |problem| "#{problem}. Either #{DOCUMENT_WAYS_OUT}" })
    end

    # The steps of a job with steps: a run stopped at a step resumes at it
    # by name, with its cursor as saved (docs/jobs.md, "Long jobs: steps").
    private def compare_steps(name : String, old : Array(JSON::Any)?, new : Array(JSON::Any)?) : Nil
      return if old.nil? && new.nil?
      if old.nil?
        @notes << "#{name}: now runs in steps"
        return
      end
      if new.nil?
        @notes << "#{name}: no longer runs in steps; a run stopped part-way starts over"
        return
      end

      old_names = old.map(&.["name"].as_s)
      new_names = new.map(&.["name"].as_s)
      old.each do |step|
        step_name = step["name"].as_s
        if counterpart = new.find(&.["name"].as_s.==(step_name))
          compare_cursor(name, step_name, step["cursor"]?, counterpart["cursor"]?)
        elsif @removals || @drop.includes?("#{name}##{step_name}")
          @notes << "#{name}##{step_name}: step removed"
        else
          @step_problems += 1
          @problems << "#{name}##{step_name} is gone, but a run may be stopped at it; a binary without the step parks such a run. " \
                       "Keep the step (renaming it is removing it), or once `punch jobs:versions` shows no unfinished #{name} in every environment, " \
                       "acknowledge it: punch jobs:lock --drop '#{name}##{step_name}'"
        end
      end
      new_names.each_with_index do |step_name, index|
        next if old_names.includes?(step_name)

        later = new_names[(index + 1)..].find { |other| old_names.includes?(other) }
        @notes << (later ? "#{name}##{step_name}: new step before #{later}; a run stopped at #{later} or after it does not run it" : "#{name}##{step_name}: new step")
      end
      kept = new_names.select { |step_name| old_names.includes?(step_name) }
      @notes << "#{name}: steps reordered; a run resumes at its step in the new order, so steps before it in the new order count as done" if kept != old_names.select { |step_name| new_names.includes?(step_name) }
    end

    private def compare_cursor(name : String, step : String, old : JSON::Any?, new : JSON::Any?) : Nil
      where = "#{name}##{step} cursor"
      if old && new
        changes = Lock.changes(old, new, where)
        unless changes.empty?
          @step_problems += changes.size
          @problems.concat(changes.map { |change| "#{change}; a run stopped at the step could not read its saved cursor. Keep the cursor's type, or give the step a new name (the old one then needs --drop)" })
        end
      elsif old
        @notes << "#{where} removed; a run stopped part-way through the step starts it over"
      elsif new
        @notes << "#{where} added; a run stopped at the step starts with none"
      end
    end

    # The breaking changes from schema *old* to schema *new*, each a
    # sentence starting with *where*.
    def self.changes(old : JSON::Any, new : JSON::Any, where : String) : Array(String)
      changes = [] of String
      compare(old, old, new, new, where, changes, 0)
      changes
    end

    private def self.compare(old_document : JSON::Any, old : JSON::Any, new_document : JSON::Any, new : JSON::Any,
                             where : String, changes : Array(String), depth : Int32) : Nil
      old, new = resolve(old_document, old), resolve(new_document, new)
      old_properties = old.as_h?.try(&.["properties"]?).try(&.as_h?)
      new_properties = new.as_h?.try(&.["properties"]?).try(&.as_h?)
      if depth < 20 && old_properties && new_properties
        compare_fields(old_document, old, old_properties, new_document, new, new_properties, where, changes)
        old_properties.each do |field, schema|
          counterpart = new_properties[field]? || next
          compare(old_document, without_null(old_document, schema), new_document, without_null(new_document, counterpart),
            "#{where}.#{field}", changes, depth + 1)
        end
      elsif depth < 20 && (old_items = items(old)) && (new_items = items(new))
        compare(old_document, old_items, new_document, new_items, "#{where}[]", changes, depth + 1)
      elsif expand(old_document, old, 0) != expand(new_document, new, 0)
        changes << "#{where} changed from #{describe(old_document, old)} to #{describe(new_document, new)}"
      end
    end

    # Which fields each side requires, against what the other always
    # writes: `to_json` leaves out a nilable field without a value.
    private def self.compare_fields(old_document : JSON::Any, old : JSON::Any, old_properties : Hash(String, JSON::Any),
                                    new_document : JSON::Any, new : JSON::Any, new_properties : Hash(String, JSON::Any),
                                    where : String, changes : Array(String)) : Nil
      required(new).each do |field|
        if !old_properties.has_key?(field)
          changes << "#{where}.#{field} is new and required: payloads written before lack it"
        elsif nullable?(old_document, old_properties[field])
          changes << "#{where}.#{field} became required: payloads written before may lack it"
        end
      end
      required(old).each do |field|
        if !new_properties.has_key?(field)
          changes << "#{where}.#{field} was removed: binaries before this one require it"
        elsif nullable?(new_document, new_properties[field])
          changes << "#{where}.#{field} may now be missing: binaries before this one require it"
        end
      end
    end

    private def self.items(schema : JSON::Any) : JSON::Any?
      hash = schema.as_h? || return
      hash["items"]? if hash["type"]? == "array"
    end

    private def self.required(schema : JSON::Any) : Array(String)
      schema["required"]?.try(&.as_a.map(&.as_s)) || [] of String
    end

    private def self.nullable?(document : JSON::Any, schema : JSON::Any) : Bool
      schema = resolve(document, schema)
      return false unless schema.as_h?

      if types = schema["type"]?.try(&.as_a?)
        types.any?(&.== "null")
      elsif options = schema["anyOf"]?.try(&.as_a?)
        options.any? { |option| resolve(document, option).as_h?.try(&.["type"]?) == "null" }
      else
        schema["type"]? == "null"
      end
    end

    # *schema* without `null`: a field's nullability is compared as
    # presence, above; its type here.
    private def self.without_null(document : JSON::Any, schema : JSON::Any) : JSON::Any
      hash = schema.as_h? || return schema
      if (types = hash["type"]?.try(&.as_a?)) && types.includes?(JSON::Any.new("null"))
        rest = types.reject(&.== "null")
        return JSON::Any.new(hash.merge({"type" => rest.size == 1 ? rest[0] : JSON::Any.new(rest)}))
      end
      if options = hash["anyOf"]?.try(&.as_a?)
        rest = options.reject { |option| resolve(document, option).as_h?.try(&.["type"]?) == "null" }
        return rest[0] if rest.size == 1 && hash.size == 1

        return JSON::Any.new(hash.merge({"anyOf" => JSON::Any.new(rest)}))
      end
      schema
    end

    private def self.resolve(document : JSON::Any, schema : JSON::Any) : JSON::Any
      10.times do
        reference = schema.as_h?.try(&.["$ref"]?).try(&.as_s?) || return schema
        target = reference.lchop("#/").split('/').reduce(document) { |node, key| node[key]? || return schema }
        schema = target
      end
      schema
    end

    # *schema* with its references replaced by what they name, for
    # comparing shapes whatever their types are called.
    private def self.expand(document : JSON::Any, schema : JSON::Any, depth : Int32) : JSON::Any
      return schema if depth > 20

      schema = resolve(document, schema)
      if hash = schema.as_h?
        JSON::Any.new(hash.reject("$defs", "description").transform_values { |value| expand(document, value, depth + 1) })
      elsif array = schema.as_a?
        JSON::Any.new(array.map { |value| expand(document, value, depth + 1) })
      else
        schema
      end
    end

    # A whole schema, expanded, for an equality check.
    def self.canonical(schema : JSON::Any) : JSON::Any
      expand(schema, schema, 0)
    end

    private def self.describe(document : JSON::Any, schema : JSON::Any) : String
      expand(document, schema, 0).to_json
    end

    private def section(document : JSON::Any?, key : String) : Hash(String, JSON::Any)
      document.try(&.[key]?).try(&.as_h?) || {} of String => JSON::Any
    end
  end
end
