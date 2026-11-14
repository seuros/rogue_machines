# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # Every Data value validates through the core at construction, so a value
  # built by hand is held to the same rule as one the gem returned.
  class ValuesTest < Minitest::Test
    def test_a_slot_is_an_index_below_the_mask_width
      assert_equal 0, Slot.new(0).index
      assert_equal EXPERIMENTS - 1, Slot.new(index: EXPERIMENTS - 1).index
      assert_raises(RangeError) { Slot.new(EXPERIMENTS) }
      assert_raises(RangeError) { Slot.new(-1) }
      assert_raises(RangeError) { Slot.new(2**64) }
      assert_raises(TypeError) { Slot.new(1.0) }
      assert_raises(TypeError) { Slot.new('1') }
    end

    def test_a_fraction_is_at_most_a_whole
      assert_equal PER_MILLION, Fraction.new(PER_MILLION).millionths
      assert_equal Fraction.new(0), Fraction::NONE
      assert_equal Fraction.new(PER_MILLION), Fraction::ALL
      assert_raises(RangeError) { Fraction.new(PER_MILLION + 1) }
      assert_raises(RangeError) { Fraction.new(-1) }
      assert_raises(TypeError) { Fraction.new(0.5) }
    end

    def test_a_draw_is_below_a_whole
      assert_equal PER_MILLION - 1, Draw.new(PER_MILLION - 1).millionths
      assert_raises(RangeError) { Draw.new(PER_MILLION) }
      assert_raises(RangeError) { Draw.new(-1) }
      assert_raises(TypeError) { Draw.new(0.0) }
    end

    def test_a_delay_is_integer_nanoseconds
      assert_equal 0, Delay.new(0).duration
      assert_equal 2**64 - 1, Delay.new(2**64 - 1).duration
      assert_raises(RangeError) { Delay.new(2**64) }
      assert_raises(RangeError) { Delay.new(-1) }
      assert_raises(TypeError) { Delay.new(0.5) }
    end

    def test_an_experiment_holds_only_the_cores_own_types
      experiment = Experiment.new(Delay.new(5), Fraction::ALL, 100)

      assert_equal [Delay.new(5), Fraction::ALL, 100], experiment.deconstruct
      assert_equal experiment, Experiment.new(fault: Delay.new(5), fraction: Fraction::ALL, expires_at: 100)
      assert_raises(RangeError) { Experiment.new(:nope, Fraction::ALL, 1) }
      assert_raises(TypeError) { Experiment.new('raise', Fraction::ALL, 1) }
      assert_raises(TypeError) { Experiment.new(:raise, 1, 1) }
      assert_raises(TypeError) { Experiment.new(:raise, Fraction::ALL, 1.0) }
      assert_raises(RangeError) { Experiment.new(:raise, Fraction::ALL, -1) }
      assert_raises(RangeError) { Experiment.new(:raise, Fraction::ALL, 2**64) }
    end

    def test_a_refused_fault_names_what_it_got
      symbol = assert_raises(RangeError) { Inject.new(:delay) }
      other = assert_raises(TypeError) { Inject.new(5) }

      assert_equal 'a fault is :raise, :garble or a Delay, got :delay', symbol.message
      assert_equal 'a fault is :raise, :garble or a Delay, got Integer', other.message
    end

    def test_the_answer_values_hold_only_what_the_core_could_answer
      experiment = Experiment.new(:garble, Fraction::NONE, 1)

      assert_equal :raise, Inject.new(:raise).fault
      assert_equal experiment, Replaced.new(experiment).experiment
      assert_equal experiment, Disarmed.new(experiment).experiment
      assert_raises(RangeError) { Inject.new(:nope) }
      assert_raises(TypeError) { Inject.new(5) }
      assert_raises(TypeError) { Replaced.new(:raise) }
      assert_raises(TypeError) { Disarmed.new(nil) }
    end

    def test_a_value_built_by_hand_equals_the_one_the_core_returns
      rogue = Rogue.new
      experiment = Experiment.new(Delay.new(7), Fraction.new(10), 100)
      rogue.arm(Slot.new(1), experiment)

      assert_equal experiment, rogue.experiment(Slot.new(1))
      assert_equal Slot.new(0), rogue.vacant
      assert_equal Replaced.new(experiment), rogue.arm(Slot.new(1), Experiment.new(:raise, Fraction::ALL, 1))
    end

    def test_the_value_predicates_are_the_cores
      experiment = Experiment.new(:raise, Fraction.new(10), 100)

      refute experiment.spent?(99)
      assert experiment.spent?(100)
      assert_raises(TypeError) { experiment.spent?(99.0) }
      assert Fraction.new(10).covers?(Draw.new(9))
      refute Fraction.new(10).covers?(Draw.new(10))
      assert_raises(TypeError) { Fraction::ALL.covers?(0) }
    end

    # Nothing skips the check: no subclass overriding `initialize`, no bare
    # `allocate`, no public hook.
    def test_values_are_final_and_their_hooks_private
      [Slot, Fraction, Draw, Delay, Experiment, Inject, Replaced, Disarmed].each do |value|
        assert_raises(TypeError) { Class.new(value) { def initialize(**) = nil } }
        assert_raises(NoMethodError) { value.allocate }
      end
      assert_raises(RangeError) { Slot.new(0).with(index: EXPERIMENTS) }
      %i[__slot __fraction __draw __delay __experiment __fault __held __spent __covers].each do |hook|
        assert_raises(NoMethodError) { RogueMachines.public_send(hook, 0) }
      end
    end
  end
end
