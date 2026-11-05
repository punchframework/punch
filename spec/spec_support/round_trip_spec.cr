require "../spec_helper"

module RoundTripSpec
  record Draft, id : Int32, note : String
  record Sent, id : Int32, note : String, due : Int32
  alias Any = Draft | Sent

  # A store that forgets `note` of sent models and turns 2 into nothing.
  def self.save_and_load(model : Any) : Any?
    case model
    in Draft then model.id == 2 ? nil : model
    in Sent  then Sent.new(model.id, "", model.due)
    end
  end
end

describe "Punch::Spec.round_trip" do
  draft = RoundTripSpec::Draft.new(1, "first")
  sent = RoundTripSpec::Sent.new(1, "first", 14)

  it "passes when every model comes back equal, in every state" do
    seen = [] of RoundTripSpec::Any
    Punch::Spec.round_trip(draft, sent, covering: RoundTripSpec::Any) do |model|
      seen << model
      model
    end
    seen.should eq([draft, sent] of RoundTripSpec::Any)
  end

  it "names each field that came back different" do
    expect_raises(Spec::AssertionFailed, %(Round trip of RoundTripSpec::Sent changed note: saved "first", loaded "")) do
      Punch::Spec.round_trip(sent) { |model| RoundTripSpec.save_and_load(model) }
    end
  end

  it "fails when the load returns nothing or another state" do
    expect_raises(Spec::AssertionFailed, "Round trip of RoundTripSpec::Draft returned nil") do
      Punch::Spec.round_trip(RoundTripSpec::Draft.new(2, "x")) { |model| RoundTripSpec.save_and_load(model) }
    end
    expect_raises(Spec::AssertionFailed, "Round trip of RoundTripSpec::Draft returned RoundTripSpec::Sent") do
      Punch::Spec.round_trip(draft) { |_| sent.as(RoundTripSpec::Any) }
    end
  end

  it "fails when a state is not covered" do
    expect_raises(Spec::AssertionFailed, "Round trip covers no RoundTripSpec::Sent: give a model in every state of (RoundTripSpec::Draft | RoundTripSpec::Sent)") do
      Punch::Spec.round_trip(draft, covering: RoundTripSpec::Any) { |model| model }
    end
  end
end
