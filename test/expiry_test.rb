# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # How the runtime applies expiry: judged at every reading, retired (and so
  # final) by the calls that take one under the lock.
  class ExpiryTest < Test
    def test_an_experiment_stops_at_its_expiry_without_anyone_disarming_it
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 10 * SECOND)
      advance((10 * SECOND) - 1)

      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }

      advance(1)

      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_an_expired_experiment_is_not_reported_as_armed
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)
      advance(SECOND)

      refute RogueMachines.armed?(:payments)
      refute RogueMachines.armed?
    end

    def test_a_clock_that_steps_backwards_after_the_expiry_was_observed_does_not_revive_it
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)
      advance(SECOND)
      assert_equal :real, RogueMachines.run(:payments) { :real }

      advance(-SECOND)

      assert_equal :real, RogueMachines.run(:payments) { :real }
      assert_empty RogueMachines.armed
    end

    def test_an_expiry_nobody_observed_is_not_reached_by_a_clock_that_steps_back
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)
      RogueMachines.clock.now_ns += SECOND
      RogueMachines.clock.now_ns -= SECOND

      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }
    end

    def test_installing_a_clock_disarms_what_the_old_one_measured
      RogueMachines.arm(:payments, fault: :garble, garbled: :x, share: 1.0, expires_in: 60 * SECOND)

      RogueMachines.clock = DeadlineMachines::TestClock.new

      refute RogueMachines.armed?
      refute_predicate RogueMachines.rogue, :any_armed?
    end

    def test_replacing_the_deadline_clock_underneath_moves_the_expiry
      RogueMachines.clock = nil
      saved = DeadlineMachines.clock
      clock = DeadlineMachines::TestClock.new
      DeadlineMachines.clock = clock
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)

      clock.now_ns += SECOND

      refute RogueMachines.armed?
    ensure
      DeadlineMachines.clock = saved
    end

    def test_one_experiment_expiring_leaves_another_running
      RogueMachines.arm(:brief, fault: :raise, share: 1.0, expires_in: SECOND)
      RogueMachines.arm(:long, fault: :garble, garbled: :x, share: 1.0, expires_in: 60 * SECOND)
      advance(SECOND)

      assert_equal :real, RogueMachines.run(:brief) { :real }
      assert_equal :x, RogueMachines.run(:long) { :real }
      assert_equal [:long], RogueMachines.armed
    end

    def test_the_run_gate_closes_again_after_an_untouched_experiment_expires
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: SECOND)
      advance(SECOND)

      # Expiry is lazy in the core: the slot is held until something retires it.
      assert_predicate RogueMachines.rogue, :any_armed?
      RogueMachines.run(:elsewhere) { :real }

      refute_predicate RogueMachines.rogue, :any_armed?
    end

    def test_an_expired_substitute_is_released_when_retired
      RogueMachines.arm(:brief, fault: :garble, garbled: Object.new, share: 1.0, expires_in: SECOND)
      RogueMachines.arm(:long, fault: :raise, share: 1.0, expires_in: 60 * SECOND)
      advance(SECOND)

      RogueMachines.armed

      assert_equal [], RogueMachines.instance_variable_get(:@substitutes).keys
    end
  end
end
