# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # The process-wide runtime: naming, arming and disarming.
  class ArmingTest < Test
    MINUTE = 60 * SECOND

    # Everything the runtime holds, read without a reading.
    def snapshot
      rogue = RogueMachines.rogue
      [rogue.armed_count, (0...EXPERIMENTS).map { |index| rogue.experiment(Slot.new(index)) },
       RogueMachines.instance_variable_get(:@slots).dup,
       RogueMachines.instance_variable_get(:@substitutes).dup]
    end

    def test_a_fresh_process_is_disarmed_and_runs_the_real_call
      refute RogueMachines.armed?
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_arming_answers_what_the_core_answered
      assert_equal :armed, RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
      answer = RogueMachines.arm(:payments, fault: :garble, share: 1.0, expires_in: MINUTE)

      assert_equal Replaced.new(Experiment.new(:raise, Fraction::ALL, MINUTE)), answer
    end

    def test_rearming_the_same_experiment_at_the_same_instant_is_an_honoured_repeat
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
      before = snapshot

      assert_equal :already_armed, RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
      assert_equal before, snapshot
    end

    # The defect: a differing substitute was stored while answering
    # :already_armed. The payload is part of what is armed, so a differing one
    # is a replacement, as a differing experiment is in the core.
    def test_rearming_with_a_different_substitute_is_a_replacement_not_a_repeat
      RogueMachines.arm(:lies, fault: :garble, garbled: [1], share: 1.0, expires_in: MINUTE)
      before = snapshot

      repeat = RogueMachines.arm(:lies, fault: :garble, garbled: [1], share: 1.0, expires_in: MINUTE)

      assert_equal :already_armed, repeat
      assert_equal before, snapshot
      answer = RogueMachines.arm(:lies, fault: :garble, garbled: [2], share: 1.0, expires_in: MINUTE)

      assert_equal Replaced.new(Experiment.new(:garble, Fraction::ALL, MINUTE)), answer
      assert_equal [2], RogueMachines.run(:lies) { :real }
    end

    def test_time_is_integer_nanoseconds_and_an_expiry_is_required
      assert_raises(ArgumentError) { RogueMachines.arm(:payments, fault: :raise, share: 1.0) }
      assert_raises(TypeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: 60.0) }
      assert_raises(TypeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: '60') }
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: 0) }
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: -1) }
      assert_raises(TypeError) { Delay.new(0.5) }
      assert_empty RogueMachines.armed
    end

    def test_the_longest_experiment_is_exactly_a_day
      day = 24 * 60 * MINUTE

      assert_equal day, LONGEST_EXPERIMENT
      assert_equal :armed, RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: day)
      assert_raises(RangeError) { RogueMachines.arm(:q, fault: :raise, share: 1.0, expires_in: day + 1) }
    end

    def test_the_longest_delay_is_exactly_five_minutes
      assert_equal 5 * MINUTE, LONGEST_DELAY
      assert_equal :armed, RogueMachines.arm(:p, fault: Delay.new(5 * MINUTE), share: 1.0, expires_in: MINUTE)
      assert_raises(RangeError) do
        RogueMachines.arm(:q, fault: Delay.new((5 * MINUTE) + 1), share: 1.0, expires_in: MINUTE)
      end
      assert_raises(RangeError) { RogueMachines.arm(:q, fault: Delay.new(0), share: 1.0, expires_in: MINUTE) }
    end

    def test_a_fault_is_raise_garble_or_a_delay
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :explode, share: 1.0, expires_in: MINUTE) }
      assert_raises(TypeError) { RogueMachines.arm(:p, fault: 'raise', share: 1.0, expires_in: MINUTE) }
      assert_raises(TypeError) { RogueMachines.arm(:p, fault: 5, share: 1.0, expires_in: MINUTE) }
    end

    def test_a_share_is_a_whole_at_most_and_expressible
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1.5, expires_in: MINUTE) }
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: -0.1, expires_in: MINUTE) }
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: Float::NAN, expires_in: MINUTE) }
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1e-7, expires_in: MINUTE) }
      assert_raises(TypeError) { RogueMachines.arm(:p, fault: :raise, share: '1', expires_in: MINUTE) }
      assert_equal :armed, RogueMachines.arm(:p, fault: :raise, share: Fraction.new(5), expires_in: MINUTE)
      assert_equal Fraction.new(5), RogueMachines.rogue.experiment(Slot.new(0)).fraction
    end

    def test_a_name_is_a_symbol_or_a_nonempty_legible_string
      assert_raises(TypeError) { RogueMachines.arm(5, fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_raises(RangeError) { RogueMachines.arm('', fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_raises(RangeError) { RogueMachines.arm(+"\xff", fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_raises(TypeError) { RogueMachines.run(5) { :real } }
      assert_raises(TypeError) { RogueMachines.disarm(nil) }
      assert_equal :armed, RogueMachines.arm('cafés', fault: :raise, share: 1.0, expires_in: MINUTE)
      assert_equal [:cafés], RogueMachines.armed
    end

    def test_a_name_whose_to_s_lies_is_armed_under_its_own_content
      liar = Class.new(String) { def to_s = 'other' }.new('payments')
      RogueMachines.arm(liar, fault: :raise, share: 1.0, expires_in: MINUTE)

      assert_equal [:payments], RogueMachines.armed
    end

    def test_a_raising_argument_changes_nothing
      RogueMachines.arm(:payments, fault: :garble, garbled: :kept, share: 1.0, expires_in: MINUTE)
      before = snapshot

      assert_raises(RangeError) { RogueMachines.arm(:payments, fault: :raise, share: 2, expires_in: MINUTE) }
      assert_raises(TypeError) { RogueMachines.arm(:other, fault: :garble, share: 1.0, expires_in: 1.0) }
      assert_equal before, snapshot
      assert_equal :kept, RogueMachines.run(:payments) { :real }
    end

    def test_an_expiry_past_the_end_of_the_clock_raises_and_changes_nothing
      RogueMachines.clock.now_ns = (2**64) - 1
      before = snapshot

      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: 1) }
      assert_equal before, snapshot
    end

    def test_running_out_of_slots_is_refused_and_changes_nothing
      EXPERIMENTS.times do |index|
        RogueMachines.arm(:"e#{index}", fault: :garble, garbled: index, share: 1.0, expires_in: MINUTE)
      end
      before = snapshot

      assert_equal :full, RogueMachines.arm(:one_more, fault: :raise, share: 1.0, expires_in: MINUTE)
      assert_equal before, snapshot
      # The names already armed can still be re-armed.
      assert_kind_of Replaced, RogueMachines.arm(:e0, fault: :raise, share: 1.0, expires_in: 2 * MINUTE)
    end

    def test_an_expired_experiment_gives_its_slot_to_the_next_arm
      EXPERIMENTS.times do |index|
        RogueMachines.arm(:"e#{index}", fault: :raise, share: 1.0, expires_in: (index + 1) * SECOND)
      end
      advance(SECOND)

      assert_equal :armed, RogueMachines.arm(:late, fault: :raise, share: 1.0, expires_in: MINUTE)
      refute_includes RogueMachines.armed, :e0
      assert_includes RogueMachines.armed, :late
    end

    def test_disarm_hands_back_what_the_name_held_and_a_repeat_is_not_armed
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)

      assert_equal Disarmed.new(Experiment.new(:raise, Fraction::ALL, MINUTE)), RogueMachines.disarm(:payments)
      before = snapshot

      assert_equal :not_armed, RogueMachines.disarm('payments')
      assert_equal before, snapshot
      # An expired experiment it still held is handed back too.
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)
      advance(SECOND)

      assert_kind_of Disarmed, RogueMachines.disarm(:payments)
    end

    # The reader hands out a frozen copy: disarming the runtime's own Rogue
    # through it would leave a name on an empty slot, which the next arm
    # hands to a second name, so one name ran the other's fault.
    def test_the_rogue_reader_cannot_disarm_behind_the_names
      RogueMachines.arm(:a, fault: :raise, share: 1.0, expires_in: MINUTE)
      rogue = RogueMachines.rogue

      assert_predicate rogue, :frozen?
      assert_raises(FrozenError) { rogue.disarm(Slot.new(0)) }
      assert_raises(FrozenError) { rogue.arm(Slot.new(1), Experiment.new(:raise, Fraction::ALL, 1)) }
      RogueMachines.arm(:b, fault: :garble, garbled: 'b', share: 1.0, expires_in: MINUTE)

      refute_equal(*RogueMachines.instance_variable_get(:@slots).values_at('a', 'b'))
      assert_raises(Injected) { RogueMachines.run(:a) { :real } }
      assert_equal 'b', RogueMachines.run(:b) { :real }
      assert_equal 2, rogue.armed_count + 1, 'a copy, taken when it was read'
    end

    # A substitute whose `==` raises is compared before anything is stored, so
    # the raise leaves every store as it was.
    def test_a_substitute_whose_equality_raises_changes_nothing
      bomb = Object.new
      def bomb.==(_) = raise(IOError, 'no comparison')
      RogueMachines.arm(:a, fault: :garble, garbled: bomb, share: 1.0, expires_in: MINUTE)
      before = snapshot

      assert_raises(IOError) { RogueMachines.arm(:a, fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_equal before, snapshot
    end

    def test_disarm_all_stops_everything_and_counts_it
      RogueMachines.arm(:a, fault: :garble, garbled: :x, share: 1.0, expires_in: MINUTE)
      RogueMachines.arm(:b, fault: :raise, share: 1.0, expires_in: MINUTE)

      assert_equal 2, RogueMachines.disarm_all
      assert_equal 0, RogueMachines.disarm_all
      assert_equal :real, RogueMachines.run(:a) { :real }
      assert_empty RogueMachines.instance_variable_get(:@substitutes)
    end

    def test_only_a_garble_keeps_the_object_it_was_armed_with
      RogueMachines.arm(:a, fault: :raise, garbled: :ignored, share: 1.0, expires_in: MINUTE)

      assert_empty RogueMachines.instance_variable_get(:@substitutes)
    end

    def test_concurrent_arming_keeps_every_substitute
      yielding = Class.new do
        def now_ns
          sleep 0.001
          DeadlineMachines::MonotonicClock.now_ns
        end
      end
      RogueMachines.clock = yielding.new

      threads = %i[a b c].map do |name|
        Thread.new { RogueMachines.arm(name, fault: :garble, garbled: name, share: 1.0, expires_in: MINUTE) }
      end
      threads.each { |thread| thread.join(10) || flunk('an arming thread never finished') }

      assert_equal(%i[a b c], %i[a b c].map { |name| RogueMachines.run(name) { :real } })
    end

    def test_a_clock_returning_an_unusable_reading_is_named_in_the_error
      RogueMachines.clock = Class.new { def now_ns = 1.5 }.new
      error = assert_raises(TypeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_match(/1\.5/, error.message)

      RogueMachines.clock = Class.new { def now_ns = -1 }.new
      assert_raises(RangeError) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: MINUTE) }
    end

    def test_a_clock_replaced_faster_than_it_can_be_read_raises_and_arms_nothing
      churn = Class.new do
        def now_ns
          RogueMachines.instance_variable_set(:@clock, self.class.new)
          0
        end
      end
      RogueMachines.clock = churn.new

      assert_raises(Error) { RogueMachines.arm(:p, fault: :raise, share: 1.0, expires_in: MINUTE) }
      assert_equal 0, RogueMachines.rogue.armed_count
      assert_empty RogueMachines.armed
    end
  end
end
