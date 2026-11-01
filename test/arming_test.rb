# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  class ArmingTest < Test
    def test_a_fresh_process_is_disarmed_and_runs_the_real_call
      refute_predicate RogueMachines, :armed?
      assert_equal :real, RogueMachines.run(:payments) { :real }
      assert_empty RogueMachines.armed
    end

    def test_an_experiment_cannot_be_armed_without_an_expiry
      assert_raises(ArgumentError) { RogueMachines.arm(:payments, fault: :raise, share: 1.0) }
    end

    def test_an_expiry_that_has_already_passed_is_refused
      [0, -1].each do |expires_in|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: expires_in)
        end
      end
    end

    def test_an_expiry_too_small_to_express_is_refused_rather_than_armed_dead
      # 5e-10 is the value that rounds UP to one nanosecond.
      [1e-12, 4.9e-10, 5.0e-10].each do |expires_in|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: expires_in)
        end
      end
      assert_empty RogueMachines.armed
    end

    def test_the_longest_experiment_is_exactly_a_day
      # A saturating float cast made the overflow guard decorative, so an
      # unbounded expires_in armed an experiment for centuries. The cap is
      # documented, so it is tested at the value either side of it.
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 86_400)

      assert_equal [:payments], RogueMachines.armed

      [86_400.1, 86_401, 1e20, 10**30].each do |expires_in|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:longer, fault: :raise, share: 1.0, expires_in: expires_in)
        end
      end
      assert_equal [:payments], RogueMachines.armed
    end

    def test_the_longest_delay_is_exactly_five_minutes
      RogueMachines.arm(:slow, fault: :delay, delay: 300, share: 0.0, expires_in: 60)

      assert_equal [:slow], RogueMachines.armed

      [300.1, 301, 10**12].each do |delay|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:slower, fault: :delay, delay: delay, share: 0.0, expires_in: 60)
        end
      end
    end

    def test_a_share_too_small_to_express_is_refused_rather_than_silently_nothing
      # 5e-7 is the value that rounds UP to one millionth, so it is the one
      # that matters: rounding would silently double the share asked for.
      [4.9e-7, 5.0e-7, 9.9e-7].each do |share|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:payments, fault: :raise, share: share, expires_in: 60)
        end
      end
      assert_empty RogueMachines.armed
    end

    def test_a_clock_returning_an_unusable_reading_is_named_in_the_error
      # The caller passed no reading, so blaming an argument would send them
      # looking in the wrong place. A bare RangeError from the conversion
      # would be worse still.
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      RogueMachines.clock.advance(-1)

      raised = assert_raises(Error) { RogueMachines.run(:unrelated) { :real } }

      assert_match(/TestClock returned -1000000000/, raised.message)

      [-> { RogueMachines.armed }, -> { RogueMachines.armed?(:payments) },
       -> { RogueMachines.disarm(:payments) },
       -> { RogueMachines.arm(:other, fault: :raise, share: 1.0, expires_in: 60) }].each do |call|
        assert_raises(Error, &call)
      end
    end

    def test_a_reading_passed_straight_to_the_registry_is_still_an_argument
      now = RogueMachines.clock.now_ns
      age = RogueMachines.registry.generation

      assert_raises(ArgumentError) { RogueMachines.registry.armed(-1, age) }
      assert_raises(ArgumentError) { RogueMachines.registry.armed(now.to_f, age) }
    end

    def test_no_reading_seam_truncates_a_float
      # Every seam that takes a reading, not just the one that decides: a
      # truncated reading silently moves an expiry.
      now = RogueMachines.clock.now_ns
      age = RogueMachines.registry.generation
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      assert_raises(ArgumentError) { RogueMachines.registry.armed(now.to_f, age) }
      assert_raises(ArgumentError) { RogueMachines.registry.armed_count(now.to_f, age) }
      assert_raises(ArgumentError) { RogueMachines.registry.disarm('payments', now.to_f, age) }
      assert_raises(ArgumentError) { RogueMachines.registry.decide('payments', now.to_f, 0, age) }
      assert_raises(ArgumentError) do
        RogueMachines.registry.arm('x', fault: 'raise', share: 1.0, expires_in: 60.0,
                                        now_ns: now.to_f, generation: age)
      end
    end

    def test_a_draw_that_is_not_an_integer_is_refused_rather_than_truncated
      # A Float draw truncates to 0, which every share covers, so a caller
      # whose rand returns a Float would inject on every call instead of none.
      RogueMachines.arm(:payments, fault: :raise, share: 1e-6, expires_in: 60)
      RogueMachines.random = Class.new { def rand(_) = 0.9999 }.new

      assert_raises(ArgumentError) { RogueMachines.run(:payments) { :real } }
    end

    def test_a_name_the_native_table_cannot_key_on_is_refused_as_an_argument
      # A call site must answer the same way whether or not something else
      # happens to be armed, so this is checked on both paths.
      names = ["\xff\xfe".b, "\xff\xfe".b.to_sym, nil, '', :'', 123]

      names.each do |name|
        assert_raises(ArgumentError) { RogueMachines.run(name) { :real } }
      end

      RogueMachines.arm(:other, fault: :raise, share: 1.0, expires_in: 60)

      names.each do |name|
        assert_raises(ArgumentError) { RogueMachines.run(name) { :real } }
      end
      assert_raises(ArgumentError) { RogueMachines.disarm("\xff\xfe".b) }
    end

    def test_the_fast_path_does_not_release_a_substitute_that_is_still_armed
      # The gate `run` reads is sampled before the lock, so an arm landing in
      # between must not have its substitute discarded.
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0,
                                   expires_in: 60)

      RogueMachines.send(:release)

      assert_equal :substitute, RogueMachines.run(:payments) { :real }
    end

    def test_an_experiment_needs_a_name
      [nil, ''].each do |name|
        assert_raises(ArgumentError) do
          RogueMachines.arm(name, fault: :raise, share: 1.0, expires_in: 60)
        end
      end
    end

    def test_a_garble_armed_with_no_substitute_returns_nil_by_design
      RogueMachines.registry.arm('direct', fault: 'garble', share: 1.0, expires_in: 60.0,
                                           now_ns: RogueMachines.clock.now_ns,
                                           generation: RogueMachines.registry.generation)

      assert_nil RogueMachines.run(:direct) { :real }
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
        Thread.new do
          RogueMachines.arm(name, fault: :garble, garbled: name, share: 1.0, expires_in: 60)
        end
      end
      threads.each { |thread| thread.join(10) || flunk('an arming thread never finished') }

      assert_equal %i[a b c], %i[a b c].map { |name| RogueMachines.run(name) { :real } }
    end

    def test_a_draw_outside_the_whole_is_refused_rather_than_biased_to_pass
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      age = RogueMachines.registry.generation
      now = RogueMachines.clock.now_ns

      [PER_MILLION, PER_MILLION + 1, 2**40, -1].each do |drawn|
        assert_raises(ArgumentError) do
          RogueMachines.registry.decide('payments', now, drawn, age)
        end
      end
    end

    def test_a_refused_arm_leaves_a_running_experiment_untouched
      RogueMachines.arm(:payments, fault: :garble, garbled: :good, share: 1.0, expires_in: 60)

      assert_raises(ArgumentError) do
        RogueMachines.arm(:payments, fault: :bogus, garbled: :bad, share: 1.0, expires_in: 60)
      end

      assert_equal :good, RogueMachines.run(:payments) { :real }
    end

    def test_a_refused_arm_leaves_no_substitute_behind
      RogueMachines.arm(:payments, fault: :garble, garbled: :good, share: 1.0, expires_in: 60)

      100.times do |index|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:"refused_#{index}", fault: :bogus, share: 1.0, expires_in: 60)
        end
      end

      assert_equal %w[payments], RogueMachines.send(:substitutes).keys
    end

    def test_a_disarm_that_raises_leaves_both_stores_untouched
      # The native call validates its reading and can raise. Removing the
      # substitute first left an armed garble with nothing to return, which
      # deferring interrupts does not prevent: a raise is not an interrupt.
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0,
                                   expires_in: 3600)
      RogueMachines.clock.advance(-1)

      assert_raises(Error) { RogueMachines.disarm(:payments) }

      RogueMachines.clock.advance(1)

      assert_equal [:payments], RogueMachines.armed
      assert_equal :substitute, RogueMachines.run(:payments) { :real }
    end

    def test_only_a_garble_keeps_the_object_it_was_armed_with
      RogueMachines.arm(:loud, fault: :raise, garbled: 'unused', share: 1.0, expires_in: 60)

      assert_nil RogueMachines.send(:substitutes).fetch('loud')
    end

    def test_a_clock_replaced_faster_than_it_can_be_read_follows_the_contract
      # The reading and the generation it belongs to are sampled separately,
      # so a mismatch means retry, and an unbounded retry is a livelock.
      # Giving up follows the documented contract rather than raising at a
      # protected call site: arming raises, a decision makes the real call, a
      # query reports nothing.
      churning = Class.new do
        def now_ns
          RogueMachines.registry.invalidate
          0
        end
      end
      RogueMachines.clock = churning.new

      assert_equal :real, RogueMachines.run(:payments) { :real }
      assert_empty RogueMachines.armed
      refute RogueMachines.armed?(:payments)
      refute RogueMachines.disarm(:payments)
      assert_raises(Error) do
        RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      end
    end

    def test_disarm_does_not_claim_an_expired_experiment_was_running
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 10)
      RogueMachines.clock.advance(10)

      refute RogueMachines.armed?(:payments)
      refute RogueMachines.disarm(:payments)
    end

    def test_a_share_outside_a_whole_is_refused
      [-0.1, 1.1, Float::NAN].each do |share|
        assert_raises(ArgumentError) do
          RogueMachines.arm(:payments, fault: :raise, share: share, expires_in: 60)
        end
      end
    end

    def test_an_unknown_fault_is_refused
      assert_raises(ArgumentError) do
        RogueMachines.arm(:payments, fault: :explode, share: 1.0, expires_in: 60)
      end
    end

    def test_a_delay_fault_needs_a_delay
      assert_raises(ArgumentError) do
        RogueMachines.arm(:slow, fault: :delay, share: 1.0, expires_in: 60)
      end
    end

    def test_disarm_all_stops_everything_and_releases_every_payload
      RogueMachines.arm(:paying, fault: :garble, garbled: :substitute, share: 1.0,
                                 expires_in: 60)
      RogueMachines.arm(:loud, fault: :raise, share: 1.0, expires_in: 60)

      RogueMachines.disarm_all

      assert_empty RogueMachines.armed
      assert_empty RogueMachines.send(:substitutes)
      assert_equal :real, RogueMachines.run(:paying) { :real }
    end

    def test_a_name_whose_to_s_lies_is_armed_under_its_own_content
      lying = Class.new(String) { def to_s = 'somewhere_else' }
      name = lying.new('mine')

      assert_equal name, RogueMachines.arm(name, fault: :garble, garbled: :substitute,
                                                 share: 1.0, expires_in: 60)
      assert_equal [:mine], RogueMachines.armed
      assert_equal :substitute, RogueMachines.run('mine') { :real }
    end

    def test_a_name_outside_ascii_round_trips_through_the_native_table
      RogueMachines.arm(:"paiements_été", fault: :garble, garbled: :substitute, share: 1.0,
                                          expires_in: 60)

      assert_equal [:"paiements_été"], RogueMachines.armed
      assert_equal :substitute, RogueMachines.run(:"paiements_été") { :real }
    end

    def test_the_capacity_is_the_width_of_the_armed_mask
      assert_equal 32, EXPERIMENTS
    end

    def test_invalidate_reports_the_generation_it_started
      before = RogueMachines.registry.generation

      assert_equal RogueMachines.registry.invalidate, RogueMachines.registry.generation
      refute_equal before, RogueMachines.registry.generation
    end

    def test_inspect_says_which_count_it_is_showing
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      assert_equal "#<RogueMachines::Rogue armed=1 of 32 at the last decision>",
                   RogueMachines.registry.inspect
    end

    def test_disarm_reports_whether_the_name_was_armed
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      assert RogueMachines.disarm(:payments)
      refute RogueMachines.disarm(:payments)
      refute_predicate RogueMachines, :armed?
    end

    def test_arming_the_same_name_again_replaces_the_experiment
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0, expires_in: 60)

      assert_equal [:payments], RogueMachines.armed
      assert_equal :substitute, RogueMachines.run(:payments) { :real }
    end

    def test_every_slot_can_be_armed_and_one_more_cannot
      EXPERIMENTS.times do |index|
        RogueMachines.arm(:"experiment_#{index}", fault: :raise, share: 1.0, expires_in: 60)
      end

      assert_equal EXPERIMENTS, RogueMachines.armed.size
      # Not assert_raises(Error): Injected is an Error too, so that would pass
      # on the wrong exception.
      refused = assert_raises(Error) do
        RogueMachines.arm(:one_too_many, fault: :raise, share: 1.0, expires_in: 60)
      end

      assert_instance_of Error, refused
      assert_match(/slots are taken/, refused.message)
    end

    def test_a_disarmed_slot_is_handed_to_the_next_experiment
      EXPERIMENTS.times do |index|
        RogueMachines.arm(:"experiment_#{index}", fault: :raise, share: 1.0, expires_in: 60)
      end
      RogueMachines.disarm(:experiment_0)

      RogueMachines.arm(:late, fault: :raise, share: 1.0, expires_in: 60)

      assert_includes RogueMachines.armed, :late
      assert_equal EXPERIMENTS, RogueMachines.armed.size
    end
  end
end
