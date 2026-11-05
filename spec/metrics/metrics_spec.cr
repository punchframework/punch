require "../spec_helper"

private def attributes(**pairs) : Punch::Metrics::Attributes
  attributes = Punch::Metrics::Attributes.new
  pairs.each { |key, value| attributes[key.to_s] = value }
  attributes
end

describe Punch::Metrics do
  describe Punch::Metrics::Histogram do
    it "counts a value on a bound in the bucket that bound closes" do
      histogram = Punch::Metrics::Histogram.new([1.0, 2.0])
      [0.5, 1.0, 1.5, 2.0, 7.0].each { |value| histogram.record(value) }
      snapshot = histogram.snapshot
      snapshot.counts.should eq([2, 2, 1])
      snapshot.count.should eq(5)
      snapshot.sum.should eq(12.0)
      {snapshot.min, snapshot.max}.should eq({0.5, 7.0})
    end

    it "refuses bounds that do not ascend" do
      expect_raises(ArgumentError, /ascending/) { Punch::Metrics::Histogram.new([1.0, 1.0]) }
    end

    it "keeps every value recorded from many threads" do
      histogram = Punch::Metrics::Histogram.new
      done = Channel(Nil).new
      8.times do
        spawn do
          1000.times { histogram.record(0.001) }
          done.send(nil)
        end
      end
      8.times { done.receive }
      histogram.count.should eq(8000)
      histogram.snapshot.counts.sum.should eq(8000)
    end
  end

  describe Punch::Metrics::Registry do
    it "collects every callback of a name into one series" do
      registry = Punch::Metrics::Registry.new
      registry.observe("app.depth", :gauge, "{job}", "Jobs waiting") { |recorder| recorder.record(3, attributes(queue: "a")) }
      registry.observe("app.depth", :gauge, "{job}", "Jobs waiting") { |recorder| recorder.record(4, attributes(queue: "b")) }
      series = registry.collect
      series.size.should eq(1)
      series.first.points.map(&.value).should eq([3_i64, 4_i64])
      series.first.kind.gauge?.should be_true
      Punch::Spec.metrics(registry).value("app.depth", queue: "b").should eq(4)
    end

    it "refuses a name registered again as another kind or unit" do
      registry = Punch::Metrics::Registry.new
      registry.observe("app.depth", :gauge, "{job}", "") { }
      expect_raises(ArgumentError, /is a Gauge in \{job\}/) { registry.observe("app.depth", :counter, "{job}", "") { } }
      expect_raises(ArgumentError, /invalid metric name/) { registry.observe("App Depth", :gauge, "1", "") { } }
    end

    it "leaves out instruments without points, and goes on past a callback that raises" do
      registry = Punch::Metrics::Registry.new
      registry.observe("app.empty", :gauge, "1", "") { }
      registry.observe("app.broken", :gauge, "1", "") { raise "boom" }
      registry.observe("app.broken", :gauge, "1", "") { |recorder| recorder.record(1, attributes) }
      registry.collect.map(&.name).should eq(["app.broken"])
      registry.names.should eq(["app.broken", "app.empty"])
    end
  end
end
