module Punch
  class View
    # Where a form is sent, as an action block describes it: the method and
    # path, the operation, and what a client must know before it sends: its
    # rate limits, whether it takes an idempotency key, and the errors of a
    # refused submission. `View#form` and `View#filter_form` give one to
    # backends that describe forms.
    struct FormTarget
      # An error of the form being shown again: at *key* (`lines[0][amount]`,
      # empty for the form as a whole), the message in the view's locale.
      record Problem, key : String, message : String, code : String

      # `GET`, `POST`, `PATCH`, `PUT`, or `DELETE`: the method a client
      # sends with, which a browser's form spells `?_method=`.
      getter method : String
      getter path : String
      # As in OpenAPI: `billing.invoices.send`.
      getter operation_id : String
      # `:none`, `:optional`, or `:required` (`Routing.idempotency`).
      getter idempotency : Symbol
      getter limits : Array(RateLimits::Limiter)
      getter problems : Array(Problem)
      # Where an agent sends it: the path with the markdown suffix, so the
      # answer is markdown without `Accept`. A Command's form takes it (the
      # page that holds the form answers it); a filter form only when its
      # page is agent-readable.
      getter markdown_path : String

      def initialize(@method : String, @path : String, @operation_id : String, @idempotency : Symbol,
                     @limits : Array(RateLimits::Limiter), @problems : Array(Problem) = [] of Problem, *, markdown : Bool = false)
        @markdown_path = markdown ? Routing.markdown_url(@path) : @path
      end

      # The target of a form for *operation* at *path*.
      def self.for(operation : O.class, method : String, path : String, problems : Array(Problem) = [] of Problem) : self forall O
        route = Routing.route(O)
        markdown = route.kind.page? ? route.agent_readable : !route.form_page.nil?
        new(method, path, route.operation_id, Routing.idempotency(O), route.rate_limits, problems, markdown: markdown)
      end

      # A read: sending it changes nothing.
      def safe? : Bool
        @method == "GET"
      end

      # Sending it twice does what sending it once does (RFC 9110).
      def idempotent? : Bool
        @method.in?("GET", "PUT", "DELETE")
      end

      # It removes what it is sent to.
      def destructive? : Bool
        @method == "DELETE"
      end
    end

    class MarkdownBackend < TreeBackend
      # Lays out the forms of a page as action blocks under one heading at
      # its end: each form's title, where it is sent, and the fields it
      # would send, as the form writes them. Format version 1.
      #
      # ```markdown
      # ## Actions
      #
      # Send an action as a form body …
      #
      # ### Send invoice
      #
      # `POST /billing/invoices/42/send` · operation `billing.invoices.send` · not idempotent · at most 30 per 1 h per user
      #
      # - `recipient` (Recipient): email address, required, now `ada@example.com`
      # - `_idempotency_key` = `1Xq…` (send it as it is, also when you retry)
      # ```
      # :nodoc:
      module Actions
        # The section, or nothing for a page without forms.
        def self.section(root : Node, locale : Locale, refused : Array(FormTarget::Problem)) : String
          forms = [] of Node
          collect(root, forms)
          targets = forms.compact_map { |form| (target = form.target) ? {form, target} : nil }
          return "" if targets.empty? && refused.empty?

          String.build do |io|
            io << "## " << phrase(locale, "heading") << "\n\n"
            unless refused.empty?
              problems(refused, locale, io)
              io << "\n\n"
            end
            io << phrase(locale, "intro")
            targets.each do |(form, target)|
              io << "\n\n"
              block(form, target, locale, io)
            end
          end
        end

        private def self.collect(node : Node, forms : Array(Node)) : Nil
          node.children.each do |child|
            next unless child.is_a?(Node)
            child.tag.form? ? (forms << child) : collect(child, forms)
          end
        end

        private def self.block(form : Node, target : FormTarget, locale : Locale, io : IO) : Nil
          controls = [] of Node
          labels = {} of String => String
          hints = {} of String => String
          buttons = [] of Node
          walk(form, controls, labels, hints, buttons)
          button = buttons.first?
          title = form["aria-label"]?.try { |label| MarkdownBackend.escape(label) }
          title ||= button.try { |found| inline(found.children) }.presence
          title ||= MarkdownBackend.escape(I18n.humanize(target.operation_id.rpartition('.').last))
          io << "### " << title << "\n\n"
          facts = ["`#{target.method} #{target.markdown_path}`", phrase(locale, "operation", id: "`#{target.operation_id}`")]
          if target.safe?
            facts << phrase(locale, "safe")
          else
            facts << phrase(locale, target.idempotent? ? "idempotent" : "not_idempotent")
            facts << phrase(locale, "destructive") if target.destructive?
          end
          target.limits.each do |limit|
            facts << phrase(locale, "limit", limit: limit.limit, period: period(limit.period), by: by(locale, limit.by))
          end
          keyed = controls.any? { |control| control["name"]? == IdempotencyKeys::FIELD }
          facts << phrase(locale, "key_optional") if target.idempotency == :optional && !keyed && !target.idempotent?
          io << facts.join(" · ")
          if target.safe?
            io << "\n\n" << phrase(locale, "query")
          end
          general = target.problems.select(&.key.empty?)
          unless general.empty?
            io << "\n\n"
            problems(general, locale, io)
          end
          lines = controls.compact_map { |control| field(control, labels, hints, target, locale) }
          return if lines.empty?

          io << "\n\n" << lines.join('\n')
        end

        # The controls, labels, hints, and buttons below *node*, in order.
        private def self.walk(node : Node, controls : Array(Node), labels : Hash(String, String),
                              hints : Hash(String, String), buttons : Array(Node)) : Nil
          node.children.each do |child|
            next unless child.is_a?(Node)

            case child.tag
            when .input?, .select?, .textarea?
              controls << child
            when .label?
              child["for"]?.try { |id| labels[id] = inline(child.children) }
            when .button?
              buttons << child
            else
              if (id = child["id"]?) && id.ends_with?("-hint")
                hints[id.rchop("-hint")] = inline(child.children)
              elsif child.tag.div? && child["class"]?.try(&.split.includes?("form-errors"))
                # The summary: the same errors are in the target.
              else
                walk(child, controls, labels, hints, buttons)
              end
            end
          end
        end

        # One field as a list item: its name as sent, its label, what it
        # takes, and its errors below.
        private def self.field(control : Node, labels : Hash(String, String), hints : Hash(String, String),
                               target : FormTarget, locale : Locale) : String?
          name = control["name"]? || return
          id = control["id"]?
          kind = control.tag.input? ? (control["type"]? || "text") : control.tag.name
          if kind == "hidden"
            # Empty is absent (docs/input.md): nothing to send.
            value = control["value"]?.presence.try { |found| code(found) } || return
            key = name == IdempotencyKeys::FIELD ? "key_field" : "hidden"
            return "- #{code(name)} = #{value} (#{phrase(locale, key)})"
          end
          parts = [] of String
          parts << description(control, kind, locale)
          parts << phrase(locale, control["required"]? ? "required" : "optional") unless kind == "checkbox"
          range(control, kind, locale).try { |text| parts << text }
          current(control, kind, locale).try { |text| parts << text }
          head = String.build do |io|
            io << "- " << code(name)
            label = id.try { |found| labels[found]? }.presence
            io << " (" << label << ')' if label
            io << ": " << parts.join(", ")
          end
          lines = [head]
          id.try { |found| hints[found]? }.presence.try { |hint| lines << "  #{hint}" }
          target.problems.each do |problem|
            lines << "  - #{problem(locale, problem)}" if problem.key == name
          end
          lines.join('\n')
        end

        private def self.description(control : Node, kind : String, locale : Locale) : String
          case kind
          when "select"
            phrase(locale, control["multiple"]? ? "any_of" : "one_of", choices: choices(control))
          when "checkbox"
            phrase(locale, "checkbox", value: code(control["value"]? || "true"))
          when "number"
            phrase(locale, control["step"]? == "1" ? "whole_number" : "number")
          when "email"
            phrase(locale, "email")
          when "text"
            control["format"]?.try(&.ends_with?("email")) ? phrase(locale, "email") : text(control, locale)
          when "password"
            phrase(locale, "password")
          else
            text(control, locale)
          end
        end

        # A select's options as `value` (label), the blank one left out.
        private def self.choices(control : Node) : String
          options = control.children.select(Node).select(&.tag.option?).reject(&.["value"]?.to_s.empty?)
          options.join(", ") do |option|
            value = option["value"]? || ""
            text = inline(option.children)
            text.empty? || text == MarkdownBackend.escape(value) ? code(value) : "#{code(value)} (#{text})"
          end
        end

        # Text, or the format it is in.
        private def self.text(control : Node, locale : Locale) : String
          case format = control["format"]?
          when "date-time" then phrase(locale, "date_time")
          when nil, ""     then phrase(locale, "text")
          else                  "#{phrase(locale, "text")} (#{code(format)})"
          end
        end

        # Lengths and ranges the control states.
        private def self.range(control : Node, kind : String, locale : Locale) : String?
          low, high = kind == "number" ? {control["min"]?, control["max"]?} : {control["minlength"]?, control["maxlength"]?}
          unit = kind == "number" ? "range" : "length"
          if low && high
            phrase(locale, "#{unit}_between", min: low, max: high)
          elsif low
            phrase(locale, "#{unit}_min", min: low)
          elsif high
            phrase(locale, "#{unit}_max", max: high)
          end
        end

        # What the form holds now, as it would send it. Passwords are
        # never written back.
        private def self.current(control : Node, kind : String, locale : Locale) : String?
          values = case kind
                   when "select"
                     control.children.select(Node).select { |option| option.tag.option? && option["selected"]? }
                       .compact_map(&.["value"]?.presence)
                   when "checkbox"
                     control["checked"]? ? [control["value"]? || "true"] : [] of String
                   when "password"
                     [] of String
                   when "textarea"
                     [plain(control.children)].reject(&.empty?)
                   else
                     [control["value"]?].compact.reject(&.empty?)
                   end
          return if values.empty?

          phrase(locale, "current", value: values.join(", ") { |value| code(value) })
        end

        # Problems as one paragraph, a line each.
        private def self.problems(problems : Array(FormTarget::Problem), locale : Locale, io : IO) : Nil
          problems.each_with_index do |problem, index|
            io << "\\\n" if index > 0
            io << (problem.key.empty? ? "" : "#{code(problem.key)}: ") << problem(locale, problem)
          end
        end

        private def self.problem(locale : Locale, problem : FormTarget::Problem) : String
          message = MarkdownBackend.escape(problem.message)
          label = locale.translate?("punch.page.problem") || "Problem"
          problem.message == problem.code ? "#{label}: #{code(problem.code)}" : "#{label}: #{message} (#{code(problem.code)})"
        end

        private def self.by(locale : Locale, by : String) : String
          locale.translate?("punch.actions.by.#{by}") || I18n::OWN.default.translate?("punch.actions.by.#{by}") || code(by)
        end

        # A period as `1 h`, `10 min`, `30 s`, or `1 d`.
        private def self.period(span : Time::Span) : String
          seconds = span.total_seconds.to_i64
          if seconds % 86_400 == 0
            "#{seconds // 86_400} d"
          elsif seconds % 3600 == 0
            "#{seconds // 3600} h"
          elsif seconds % 60 == 0
            "#{seconds // 60} min"
          else
            "#{seconds} s"
          end
        end

        # A phrase of the block in *locale* (`punch.actions.*`), its values
        # written in; Punch's English while an app's catalog predates it
        # (`punch check` reports that).
        private def self.phrase(locale : Locale, key : String, **values) : String
          params = {} of String => Invalid::Param
          values.each { |name, value| params[name.to_s] = value.to_s }
          locale.translate?("punch.actions.#{key}", params) || I18n::OWN.default.translate?("punch.actions.#{key}", params) || key
        end

        private def self.inline(children : Array(Node | String)) : String
          line = Inline.new(true)
          children.each do |child|
            case child
            in String then line.text(child)
            in Node   then line.text(plain(child.children))
            end
          end
          line.to_s
        end

        private def self.plain(children : Array(Node | String)) : String
          String.build do |io|
            children.each do |child|
              case child
              in String then io << child
              in Node   then io << plain(child.children)
              end
            end
          end
        end

        # A value as a code span, so it is copied exactly.
        private def self.code(text : String) : String
          line = Inline.new(true)
          line.code(text)
          text.strip.empty? ? "`\"\"`" : line.to_s
        end
      end
    end
  end
end
