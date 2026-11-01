# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  class ExpiryTest < Test
    def test_an_experiment_stops_at_its_expiry_without_anyone_disarming_it
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      RogueMachines.clock.advance(59)
      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }

      RogueMachines.clock.advance(1)
      assert_equal :real, RogueMachines.run(:payments) { :real }
      refute_predicate RogueMachines, :armed?
    end

    def test_an_expired_experiment_is_not_reported_as_armed
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      RogueMachines.clock.advance(60)

      assert_empty RogueMachines.armed
      refute RogueMachines.armed?(:payments)
    end

    def test_a_clock_that_steps_backwards_after_the_expiry_was_observed_does_not_revive_it
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      RogueMachines.clock.advance(60)

      assert_equal :real, RogueMachines.run(:payments) { :real }

      RogueMachines.clock.advance(-30)
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_an_expiry_nobody_observed_is_not_reached_by_a_clock_that_steps_back
      # Pinning a limitation rather than a feature. An expiry is observed, not
      # scheduled, and one reading cannot tell a backwards step from less time
      # having passed, so 30 seconds genuinely remain on this clock.
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      RogueMachines.clock.advance(60)
      RogueMachines.clock.advance(-30)

      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }
    end

    def test_installing_a_clock_disarms_what_the_old_one_measured
      RogueMachines.clock = DeadlineMachines::MonotonicClock
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      RogueMachines.clock = DeadlineMachines::TestClock.new

      assert_empty RogueMachines.armed
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_replacing_the_deadline_clock_underneath_moves_the_expiry
      RogueMachines.clock = nil
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      DeadlineMachines.clock = DeadlineMachines::TestClock.new(now_ns: 10**18)
      DeadlineMachines.clock.advance(60)

      assert_empty RogueMachines.armed
    ensure
      DeadlineMachines.clock = DeadlineMachines::MonotonicClock
    end

    def test_an_experiment_survives_a_deadline_clock_swapped_to_a_lower_epoch
      # Pinning a limitation. Nothing is inferred from a reading that looks
      # early, so only RogueMachines.clock= disarms.
      RogueMachines.clock = nil
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      DeadlineMachines.clock = DeadlineMachines::TestClock.new
      DeadlineMachines.clock.advance(86_400)

      assert_equal [:payments], RogueMachines.armed
    ensure
      DeadlineMachines.clock = DeadlineMachines::MonotonicClock
    end

    def test_an_expired_experiment_is_not_counted_before_anything_lists_it
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 10)
      RogueMachines.clock.advance(10)

      assert_equal 0, RogueMachines.registry.armed_count(RogueMachines.clock.now_ns,
                                                          RogueMachines.registry.generation)
    end

    def test_an_expired_substitute_is_released_while_another_experiment_is_armed
      RogueMachines.arm(:gone, fault: :garble, garbled: 'payload', share: 1.0, expires_in: 10)
      RogueMachines.arm(:holds_the_gate, fault: :raise, share: 1.0, expires_in: 600)
      RogueMachines.clock.advance(10)

      RogueMachines.run(:anything) { :real }

      assert_equal %w[holds_the_gate], RogueMachines.send(:substitutes).keys
    end

    def test_one_experiment_expiring_leaves_another_running
      RogueMachines.arm(:brief, fault: :raise, share: 1.0, expires_in: 10)
      RogueMachines.arm(:long, fault: :raise, share: 1.0, expires_in: 600)

      RogueMachines.clock.advance(10)

      assert_equal :real, RogueMachines.run(:brief) { :real }
      assert_raises(Injected) { RogueMachines.run(:long) { :real } }
      assert_equal [:long], RogueMachines.armed
    end

    def test_the_run_gate_closes_again_after_an_untouched_experiment_expires
      RogueMachines.arm(:never_called, fault: :raise, share: 1.0, expires_in: 10)
      RogueMachines.clock.advance(10)

      assert_equal :real, RogueMachines.run(:something_else) { :real }
      refute_predicate RogueMachines.registry, :any_armed?
    end

    def test_expired_experiments_release_their_slots
      EXPERIMENTS.times do |index|
        RogueMachines.arm(:"burst_#{index}", fault: :raise, share: 1.0, expires_in: 10)
      end
      RogueMachines.clock.advance(10)

      RogueMachines.arm(:after_the_burst, fault: :raise, share: 1.0, expires_in: 10)

      assert_equal [:after_the_burst], RogueMachines.armed
    end

    def test_an_expired_experiments_substitute_is_not_kept
      RogueMachines.arm(:gone, fault: :garble, garbled: :stale, share: 1.0, expires_in: 10)
      RogueMachines.clock.advance(10)

      RogueMachines.arm(:fresh, fault: :raise, share: 1.0, expires_in: 10)

      assert_equal %w[fresh], RogueMachines.send(:substitutes).keys
    end

    def test_reading_the_armed_list_releases_an_expired_substitute
      RogueMachines.arm(:gone, fault: :garble, garbled: :stale, share: 1.0, expires_in: 10)
      RogueMachines.clock.advance(10)

      assert_empty RogueMachines.armed
      assert_empty RogueMachines.send(:substitutes)
    end

    def test_the_disarmed_fast_path_releases_a_substitute_on_its_own
      # Seeded directly with nothing armed, so only the fast path's own
      # release can clear it. Going through an expiry instead let reconcile
      # do the work and the test passed with release deleted.
      RogueMachines.send(:publish, { 'ghost' => :stale }, ['ghost'])

      refute_empty RogueMachines.send(:substitutes)

      RogueMachines.run(:unrelated) { :real }

      assert_empty RogueMachines.send(:substitutes)
    end
  end
end
