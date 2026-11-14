# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # The plain mirror of the core's Rogue: positional, Integer nanoseconds.
  class RogueTest < Minitest::Test
    def setup
      @rogue = Rogue.new
    end

    def raising(expires_at) = Experiment.new(:raise, Fraction::ALL, expires_at)

    # Everything the Rogue answers, read through queries that change nothing.
    def state(now = 0)
      slots = (0...EXPERIMENTS).map { |index| Slot.new(index) }
      [@rogue.any_armed?, @rogue.armed_count, @rogue.live_count(now), @rogue.vacant,
       slots.map { |slot| @rogue.experiment(slot) }]
    end

    def test_a_fresh_rogue_injects_nothing
      refute_predicate @rogue, :any_armed?
      assert_equal 0, @rogue.armed_count
      assert_equal Slot.new(0), @rogue.vacant
      assert_equal :pass, @rogue.decide(Slot.new(0), 0, Draw.new(0))
      assert_nil @rogue.experiment(Slot.new(0))
      assert_nil @rogue.active(Slot.new(0), 0)
    end

    def test_arming_says_what_the_slot_held_before
      first = raising(100)
      second = Experiment.new(Delay.new(5), Fraction::ALL, 100)

      assert_equal :armed, @rogue.arm(Slot.new(0), first)
      assert_equal Replaced.new(first), @rogue.arm(Slot.new(0), second)
      assert_equal Inject.new(Delay.new(5)), @rogue.decide(Slot.new(0), 0, Draw.new(0))
    end

    def test_arming_the_identical_experiment_again_is_an_honoured_repeat_that_changes_nothing
      @rogue.arm(Slot.new(3), raising(100))
      before = state

      assert_equal :already_armed, @rogue.arm(Slot.new(3), raising(100))
      assert_equal before, state
    end

    def test_disarming_says_what_the_slot_held_and_a_repeat_changes_nothing
      @rogue.arm(Slot.new(0), raising(100))

      assert_equal Disarmed.new(raising(100)), @rogue.disarm(Slot.new(0))
      before = state

      assert_equal :not_armed, @rogue.disarm(Slot.new(0))
      assert_equal before, state
    end

    def test_disarm_all_counts_what_it_emptied
      @rogue.arm(Slot.new(0), raising(100))
      @rogue.arm(Slot.new(5), raising(1))

      assert_equal 2, @rogue.disarm_all
      assert_equal 0, @rogue.disarm_all
      refute_predicate @rogue, :any_armed?
    end

    def test_queries_judge_expiry_against_their_own_instant_and_change_nothing
      @rogue.arm(Slot.new(7), raising(100))
      before = state(100)

      assert_equal :pass, @rogue.decide(Slot.new(7), 100, Draw.new(0))
      assert_nil @rogue.active(Slot.new(7), 100)
      assert_equal 0, @rogue.live_count(100)
      assert_equal before, state(100)
      assert_predicate @rogue, :any_armed?
      # Nothing was recorded, so an earlier instant still finds it live.
      assert_equal Inject.new(:raise), @rogue.decide(Slot.new(7), 99, Draw.new(0))
    end

    def test_only_a_sweep_empties_an_expired_slot
      @rogue.arm(Slot.new(7), raising(100))
      @rogue.arm(Slot.new(8), raising(200))

      assert_equal 0, @rogue.sweep(99)
      assert_equal 1, @rogue.sweep(100)
      assert_nil @rogue.experiment(Slot.new(7))
      assert_equal :pass, @rogue.decide(Slot.new(7), 0, Draw.new(0))
      assert_equal 1, @rogue.armed_count
    end

    def test_every_slot_can_be_armed_and_then_none_is_vacant
      EXPERIMENTS.times { |index| @rogue.arm(Slot.new(index), raising(100)) }

      assert_nil @rogue.vacant
      assert_equal EXPERIMENTS, @rogue.armed_count
    end

    def test_malformed_arguments_raise_before_the_core_changes_anything
      @rogue.arm(Slot.new(0), raising(100))
      before = state

      assert_raises(TypeError) { @rogue.arm(0, raising(1)) }
      assert_raises(TypeError) { @rogue.arm(Slot.new(1), :raise) }
      assert_raises(TypeError) { @rogue.disarm(0) }
      assert_raises(TypeError) { @rogue.sweep(1.5) }
      assert_raises(RangeError) { @rogue.sweep(-1) }
      assert_raises(TypeError) { @rogue.decide(Slot.new(0), 0, 0) }
      assert_equal before, state
    end

    def test_a_frozen_rogue_refuses_to_mutate
      @rogue.arm(Slot.new(0), raising(100))
      @rogue.freeze
      before = state

      assert_raises(FrozenError) { @rogue.arm(Slot.new(1), raising(1)) }
      assert_raises(FrozenError) { @rogue.disarm(Slot.new(0)) }
      assert_raises(FrozenError) { @rogue.disarm_all }
      assert_raises(FrozenError) { @rogue.sweep(1_000) }
      assert_equal before, state
    end

    # Frozen is checked before any argument is read, as Ruby's own methods do.
    def test_a_frozen_rogue_given_a_bad_argument_raises_frozen_error
      @rogue.freeze

      assert_raises(FrozenError) { @rogue.arm(:slot, :experiment) }
      assert_raises(FrozenError) { @rogue.disarm(1.5) }
      assert_raises(FrozenError) { @rogue.sweep(-1) }
    end

    def test_instants_and_spans_are_integer_nanoseconds_in_and_out
      @rogue.arm(Slot.new(0), Experiment.new(Delay.new(2**64 - 1), Fraction::ALL, 2**64 - 1))

      held = @rogue.active(Slot.new(0), 2**64 - 2)

      assert_equal 2**64 - 1, held.expires_at
      assert_equal 2**64 - 1, held.fault.duration
      assert_nil @rogue.active(Slot.new(0), 2**64 - 1)
    end

    def test_inspect_names_the_count
      assert_equal "#<RogueMachines::Rogue armed=0 of #{EXPERIMENTS}>", @rogue.inspect
    end

    def test_a_copy_holds_the_same_experiments_and_moves_on_its_own
      @rogue.arm(Slot.new(0), raising(100))
      copy = @rogue.dup
      copy.disarm(Slot.new(0))

      assert_equal raising(100), @rogue.experiment(Slot.new(0))
      assert_nil copy.experiment(Slot.new(0))
      assert_predicate @rogue.freeze.clone, :frozen?
      refute_predicate @rogue.clone(freeze: false), :frozen?
      assert_equal raising(100), @rogue.clone.experiment(Slot.new(0))
    end

    def test_it_cannot_be_allocated_without_new
      assert_raises(TypeError) { Rogue.allocate }
    end
  end
end
