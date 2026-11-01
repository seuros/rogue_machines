# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  class DeadlineTest < Test
    def setup
      super
      # The stall sleeps for real, so this clock is the wall one again.
      RogueMachines.clock = DeadlineMachines::MonotonicClock
    end

    def test_a_delay_longer_than_the_deadline_trips_it_instead_of_sleeping_past_it
      RogueMachines.arm(:slow, fault: :delay, delay: 30, share: 1.0, expires_in: 60)

      elapsed = DeadlineMachines.with_deadline(0.05) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(DeadlineMachines::Error) { RogueMachines.run(:slow) { :real } }
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      # The budget is 0.05s against a 30s delay, so anything near a second
      # means the clamp was ignored.
      assert_operator elapsed, :<, 0.5
    end

    def test_a_delay_inside_the_deadline_still_makes_the_real_call
      RogueMachines.arm(:slow, fault: :delay, delay: 0.001, share: 1.0, expires_in: 60)

      DeadlineMachines.with_deadline(5) do
        assert_equal :real, RogueMachines.run(:slow) { :real }
      end
    end

    def test_a_spent_deadline_raises_before_the_delay_rather_than_sleeping_forever
      RogueMachines.arm(:slow, fault: :delay, delay: 30, share: 1.0, expires_in: 60)

      DeadlineMachines.with_deadline(0.001) do
        sleep 0.01
        assert_raises(DeadlineMachines::Error) { RogueMachines.run(:slow) { :real } }
      end
    end

    def test_a_delay_with_no_deadline_is_left_alone
      RogueMachines.arm(:slow, fault: :delay, delay: 0.001, share: 1.0, expires_in: 60)

      assert_equal :real, RogueMachines.run(:slow) { :real }
    end
  end
end
