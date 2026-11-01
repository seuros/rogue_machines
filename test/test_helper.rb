# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rogue_machines'
require 'minitest/autorun'

# A draw the test chooses, so a share's boundary is exact rather than sampled.
class FixedDraw
  def initialize(value) = @value = value

  def rand(_bound) = @value
end

module RogueMachines
  class Test < Minitest::Test
    def setup
      RogueMachines.clock = DeadlineMachines::TestClock.new
      RogueMachines.random = FixedDraw.new(0)
    end

    def teardown
      RogueMachines.disarm_all
      RogueMachines.clock = nil
      RogueMachines.random = nil
    end

    def draws(value)
      RogueMachines.random = FixedDraw.new(value)
    end
  end
end
