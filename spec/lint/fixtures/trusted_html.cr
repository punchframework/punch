# Fixture for Punch/TrustedHTML: SafeHTML.trusted with anything but a literal.
icon = Punch::SafeHTML.trusted(%(<svg aria-hidden="true"></svg>))
block = Punch::SafeHTML.trusted <<-HTML
  <svg viewBox="0 0 1 1"></svg>
  HTML
name = "Ada"
greeting = Punch::SafeHTML.trusted("<b>#{name}</b>") # expect
stored = SafeHTML.trusted(name)                      # expect
built = Punch::SafeHTML.trusted("<i>" + name)        # expect
other = Markup.trusted(name)                         # expect
klass = Punch::SafeHTML
held = klass.trusted(name)                                                                            # expect
response = HTTP::Response.new(:ok, name, HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"}) # expect

macro wrap(value)
  Punch::SafeHTML.trusted({{ value }}) # expect
  Punch::SafeHTML.trusted("<hr>")
end

{% begin %}
  Punch::SafeHTML.trusted(name) # expect
{% end %}

struct Punch::SafeHTML # expect
  def self.mine(value : String)
    new(value)
  end
end
