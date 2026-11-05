module Punch
  class View
    # Every element a view can write, with what it is and what it may hold:
    # `{category, content}`.
    #
    # Categories: `flow` (a block, such as a paragraph or a list),
    # `phrasing` (inside text, such as `strong` or a link), and `part`
    # (only inside one parent: `li`, table rows and cells).
    #
    # Contents: `flow` (blocks and text), `phrasing` (text and phrasing
    # elements only), `list` (`li`), `terms` (`dt`, `dd`), `table`
    # (`caption`, `thead`, `tbody`, `tfoot`), `rows` (`tr`), `cells` (`th`,
    # `td`), `details` (`summary` and blocks), `none` (void elements).
    #
    # The models follow HTML's, narrowed where markdown has no equivalent:
    # a link holds only phrasing content, and rows sit inside `thead`,
    # `tbody`, or `tfoot`.
    ELEMENTS = {
      div:        {:flow, :flow},
      main:       {:flow, :flow},
      header:     {:flow, :flow},
      footer:     {:flow, :flow},
      nav:        {:flow, :flow},
      aside:      {:flow, :flow},
      section:    {:flow, :flow},
      article:    {:flow, :flow},
      blockquote: {:flow, :flow},
      fieldset:   {:flow, :flow},
      legend:     {:part, :phrasing},
      details:    {:flow, :details},
      summary:    {:part, :phrasing},
      p:          {:flow, :phrasing},
      h1:         {:flow, :phrasing},
      h2:         {:flow, :phrasing},
      h3:         {:flow, :phrasing},
      h4:         {:flow, :phrasing},
      h5:         {:flow, :phrasing},
      h6:         {:flow, :phrasing},
      pre:        {:flow, :phrasing},
      hr:         {:flow, :none},
      ul:         {:flow, :list},
      ol:         {:flow, :list},
      li:         {:part, :flow},
      dl:         {:flow, :terms},
      dt:         {:part, :phrasing},
      dd:         {:part, :flow},
      table:      {:flow, :table},
      caption:    {:part, :phrasing},
      thead:      {:part, :rows},
      tbody:      {:part, :rows},
      tfoot:      {:part, :rows},
      tr:         {:part, :cells},
      th:         {:part, :flow},
      td:         {:part, :flow},
      a:          {:phrasing, :phrasing},
      span:       {:phrasing, :phrasing},
      strong:     {:phrasing, :phrasing},
      em:         {:phrasing, :phrasing},
      b:          {:phrasing, :phrasing},
      i:          {:phrasing, :phrasing},
      s:          {:phrasing, :phrasing},
      u:          {:phrasing, :phrasing},
      small:      {:phrasing, :phrasing},
      mark:       {:phrasing, :phrasing},
      code:       {:phrasing, :phrasing},
      kbd:        {:phrasing, :phrasing},
      samp:       {:phrasing, :phrasing},
      var:        {:phrasing, :phrasing},
      abbr:       {:phrasing, :phrasing},
      cite:       {:phrasing, :phrasing},
      dfn:        {:phrasing, :phrasing},
      q:          {:phrasing, :phrasing},
      time:       {:phrasing, :phrasing},
      del:        {:phrasing, :phrasing},
      ins:        {:phrasing, :phrasing},
      sub:        {:phrasing, :phrasing},
      sup:        {:phrasing, :phrasing},
      img:        {:phrasing, :none},
      br:         {:phrasing, :none},
      wbr:        {:phrasing, :none},
    }

    # Elements only Punch writes, with what they are and hold, as in
    # `ELEMENTS`: forms and their controls (`View#form`, `View::Form`) and
    # Turbo Frames (`View#frame`). A control belongs inside a form.
    CONTROLS = {
      form:        {:flow, :flow},
      label:       {:phrasing, :phrasing},
      input:       {:phrasing, :none},
      textarea:    {:phrasing, :phrasing},
      select:      {:phrasing, :options},
      option:      {:part, :phrasing},
      button:      {:phrasing, :phrasing},
      turbo_frame: {:flow, :flow},
    }

    # Which parents each `part` element needs.
    PARTS = {
      legend:  {:fieldset},
      option:  {:select},
      summary: {:details},
      li:      {:ul, :ol},
      dt:      {:dl},
      dd:      {:dl},
      caption: {:table},
      thead:   {:table},
      tbody:   {:table},
      tfoot:   {:table},
      tr:      {:thead, :tbody, :tfoot},
      th:      {:tr},
      td:      {:tr},
    }

    # One element of `ELEMENTS`, plus the document structure that
    # `View#document` writes.
    enum Tag
      {% for name in ELEMENTS %}
        {{ name.id.camelcase }}
      {% end %}
      {% for name in CONTROLS %}
        {{ name.id.camelcase }}
      {% end %}
      Html
      Head
      Body
      # The root of a fragment, a view that is not a whole document.
      Fragment
      # The root of a Turbo Stream action's content (`Punch::TurboStream`),
      # which goes wherever its target is, so it may hold any element.
      Template

      # The element's name in markup.
      def name : String
        {% begin %}
        case self
        {% for name in ELEMENTS.keys + CONTROLS.keys %}
          in {{ name.id.camelcase }} then {{ name.stringify.gsub(/_/, "-") }}
        {% end %}
        in Html     then "html"
        in Head     then "head"
        in Body     then "body"
        in Fragment then "fragment"
        in Template then "template"
        end
        {% end %}
      end

      def phrasing? : Bool
        {% begin %}
        case self
        {% for name, spec in ELEMENTS %}
          {% if spec[0] == :phrasing %}
            when {{ name.id.camelcase }} then true
          {% end %}
        {% end %}
        {% for name, spec in CONTROLS %}
          {% if spec[0] == :phrasing %}
            when {{ name.id.camelcase }} then true
          {% end %}
        {% end %}
        else false
        end
        {% end %}
      end

      def void? : Bool
        {% begin %}
        case self
        {% for name, spec in ELEMENTS %}
          {% if spec[1] == :none %}
            when {{ name.id.camelcase }} then true
          {% end %}
        {% end %}
        when Input then true
        else false
        end
        {% end %}
      end

      # A form control, which belongs inside a form.
      def control? : Bool
        label? || input? || textarea? || select? || option? || button?
      end

      # Whether text may appear directly inside.
      def holds_text? : Bool
        content.in?(:flow, :phrasing, :details, :any)
      end

      # What the element may hold, as in `ELEMENTS`.
      def content : Symbol
        {% begin %}
        case self
        {% for name, spec in ELEMENTS %}
          when {{ name.id.camelcase }} then {{ spec[1] }}
        {% end %}
        {% for name, spec in CONTROLS %}
          when {{ name.id.camelcase }} then {{ spec[1] }}
        {% end %}
        when Html then :document
        when Head     then :none
        when Template then :any
        else               :flow
        end
        {% end %}
      end

      # Whether *child* may appear directly inside this element.
      def allows?(child : Tag) : Bool
        return true if template?
        {% begin %}
        case child
        {% for name, parents in PARTS %}
          when {{ name.id.camelcase }} then {{ parents.map { |parent| "self == #{parent.id.camelcase}".id }.join(" || ").id }}
        {% end %}
        else
          case content
          when :flow, :details then true
          when :phrasing       then child.phrasing?
          else                      false
          end
        end
        {% end %}
      end

      # Containers of parts and blocks, whose markup reads better with a
      # line break after the start tag.
      def breaks_after_start? : Bool
        content.in?(:list, :terms, :table, :rows, :cells, :options, :document) || body?
      end
    end
  end
end
