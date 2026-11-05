module Punch::Spec
  # Runs the block with caching off, as `PUNCH_CACHE=off` does for a whole
  # run: every fetch computes.
  def self.without_cache(&)
    previous = Caches.enabled?
    Caches.enabled = false
    begin
      yield
    ensure
      Caches.enabled = previous
    end
  end

  # :nodoc:
  def self.reset_caches : Nil
    Caches.enabled = ENV["PUNCH_CACHE"]? != "off"
    Caches.clear
  end
end

# Stores in the durable tier write to an in-memory `cache.db`; every example
# starts with empty stores and `PUNCH_CACHE=off` makes every fetch compute
# (`punch check` runs app specs once that way).
Punch::Caches.attach(Punch::Caches::Durable.new(Punch::Database.memory(name: "cache", config: Punch::Database::Config.new(readers: 2))))
Punch::Caches.enabled = ENV["PUNCH_CACHE"]? != "off"
Spec.before_each { Punch::Spec.reset_caches }
