module Punch
  # `/llms.txt` (llmstxt.org): where an agent given only the base URL
  # starts. It names the app, says once how to read pages, sign in with a
  # token, act, and retry, and lists the agent-readable pages marked as
  # entry points (`@[Punch::AgentReadable(entry: true)]`) at their `.md`
  # URLs. An app without entry points has no `/llms.txt`.
  #
  # The app's own text comes from its locale files, in the request's
  # language: `llms.title`, `llms.summary`, and per entry point
  # `llms.pages.<operation id>.title` and `.description`. Punch's
  # paragraphs are `punch.llms.*`.
  module LLMs
    PATH         = "/llms.txt"
    CONTENT_TYPE = "text/plain; charset=utf-8"

    # The document for *entries* (routes of entry points) in *locale*.
    # With *openapi*, the JSON API's contract is listed as optional.
    def self.render(entries : Array(Routing::Route), locale : Locale, *, openapi : Bool = false) : String
      String.build do |io|
        io << "# " << (app(locale, "llms.title") || own(locale, "untitled")) << "\n\n"
        if summary = app(locale, "llms.summary")
          io << "> " << summary << "\n\n"
        end
        hours = IdempotencyKeys.retention.to_i // 3600
        {"read", "sign_in", "act", "retry", "limits"}.each do |key|
          io << own(locale, key, hours: hours) << "\n\n"
        end
        io << "## " << own(locale, "pages") << "\n\n"
        entries.each do |route|
          key = "llms.pages.#{route.operation_id}"
          title = app(locale, "#{key}.title") || I18n.humanize(route.operation_id.gsub('.', '_'))
          io << "- [" << title << "](" << Routing.markdown_url(route.template) << ')'
          if description = app(locale, "#{key}.description")
            io << ": " << description
          end
          io << '\n'
        end
        if openapi
          # "Optional" is llmstxt.org's name for links an agent may skip.
          io << "\n## Optional\n\n- [OpenAPI](/openapi.json): " << own(locale, "openapi") << '\n'
        end
      end
    end

    private def self.app(locale : Locale, key : String) : String?
      locale.translate?(key).presence
    end

    private def self.own(locale : Locale, key : String, **values) : String
      params = {} of String => Invalid::Param
      values.each { |name, value| params[name.to_s] = value.to_s }
      key = "punch.llms.#{key}"
      locale.translate?(key, params) || I18n::OWN.default.translate?(key, params) || key
    end
  end
end
