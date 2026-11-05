require "../spec_helper"

module ProblemSpec
  @[Punch::Status(404)]
  struct Gone
    include Punch::Problem
  end

  @[Punch::Status(409)]
  struct Busy
    include Punch::Problem

    getter reason : String

    def initialize(@reason : String)
    end
  end
end

describe Punch::Problem do
  it "is a failure with no fields that is made empty and serializes" do
    ProblemSpec::Gone.new.to_json.should eq("{}")
    ProblemSpec::Gone.from_json("{}").should be_a(ProblemSpec::Gone)
  end

  it "keeps its own constructor and fields" do
    ProblemSpec::Busy.new("later").to_json.should eq(%({"reason":"later"}))
  end
end
