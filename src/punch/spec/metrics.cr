module Punch::Spec
  # The metrics *registry* holds now (by default the process's), for
  # looking values up by name and attributes:
  #
  # ```
  # registry = Punch::Metrics::Registry.new
  # db.observe(registry)
  # metrics = Punch::Spec.metrics(registry)
  # metrics.value("punch.db.wal.frames", "db.namespace": "primary").should be > 0
  # metrics.distribution("punch.db.checkpoint.duration").count.should eq(1)
  # ```
  def self.metrics(registry : Punch::Metrics::Registry = Punch::Metrics.registry) : CollectedMetrics
    CollectedMetrics.new(registry.collect)
  end

  # What `Punch::Spec.metrics` collected.
  struct CollectedMetrics
    getter series : Array(Punch::Metrics::Series)

    def initialize(@series : Array(Punch::Metrics::Series))
    end

    # The value of the one point of *name* whose attributes include
    # *attributes*. Fails the example if none or several match.
    def value(name : String, **attributes) : Int64 | Float64
      value = point(name, attributes).value
      fail "#{name} is a histogram: use distribution" if value.is_a?(Punch::Metrics::Distribution)
      value
    end

    def distribution(name : String, **attributes) : Punch::Metrics::Distribution
      value = point(name, attributes).value
      fail "#{name} is not a histogram" unless value.is_a?(Punch::Metrics::Distribution)
      value
    end

    # Whether *name* has a point whose attributes include *attributes*.
    def has?(name : String, **attributes) : Bool
      !points(name, attributes).empty?
    end

    private def point(name : String, attributes) : Punch::Metrics::Point
      found = points(name, attributes)
      fail "no point of #{name} with #{attributes}; collected: #{series.map(&.name).join(", ")}" if found.empty?
      fail "#{found.size} points of #{name} match #{attributes}: name more attributes" if found.size > 1
      found.first
    end

    private def points(name : String, attributes) : Array(Punch::Metrics::Point)
      series.select(&.name.==(name)).flat_map(&.points).select do |point|
        matches = true
        attributes.each { |key, expected| matches &&= point.attributes[key.to_s]? == expected }
        matches
      end
    end
  end
end
