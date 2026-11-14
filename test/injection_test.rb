# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # What `run` does with each fault.
  class InjectionTest < Test
    MINUTE = 60 * SECOND

    def test_a_raise_fault_raises_instead_of_running_the_block
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)
      ran = false

      assert_raises(Injected) { RogueMachines.run(:payments) { ran = true } }
      refute ran
      # Only under the name it was armed under.
      assert_equal :real, RogueMachines.run(:search) { :real }
    end

    def test_a_garble_fault_returns_the_substitute_instead_of_running_the_block
      RogueMachines.arm(:payments, fault: :garble, garbled: { ok: false }, share: 1.0, expires_in: MINUTE)

      assert_equal({ ok: false }, RogueMachines.run(:payments) { :real })
      # With no `garbled:`, the substitute is nil rather than the real value.
      RogueMachines.arm(:other, fault: :garble, share: 1.0, expires_in: MINUTE)

      assert_nil RogueMachines.run(:other) { :real }
    end

    def test_a_delay_fault_waits_and_then_makes_the_real_call
      RogueMachines.arm(:slow, fault: Delay.new(SECOND / 100), share: 1.0, expires_in: MINUTE)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

      assert_equal :real, RogueMachines.run(:slow) { :real }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started, :>=, SECOND / 100
    end

    def test_the_share_is_half_open_so_the_boundary_draw_makes_the_real_call
      RogueMachines.arm(:payments, fault: :raise, share: 0.1, expires_in: MINUTE)

      draws(99_999)
      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }
      draws(100_000)
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_a_share_of_zero_is_armed_and_reaches_nothing
      RogueMachines.arm(:payments, fault: :raise, share: 0, expires_in: MINUTE)

      assert RogueMachines.armed?(:payments)
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_a_draw_outside_the_whole_raises_rather_than_biasing_to_pass
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: MINUTE)

      draws(PER_MILLION)
      assert_raises(RangeError) { RogueMachines.run(:payments) { :real } }
      draws(0.5)
      assert_raises(TypeError) { RogueMachines.run(:payments) { :real } }
    end

    def test_a_seeded_random_replays_the_same_calls
      RogueMachines.arm(:payments, fault: :garble, garbled: :x, share: 0.5, expires_in: MINUTE)
      replay = lambda do
        RogueMachines.random = Random.new(42)
        Array.new(50) { RogueMachines.run(:payments) { :real } }
      end

      assert_equal replay.call, replay.call
    end
  end
end
