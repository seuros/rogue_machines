# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  class InjectionTest < Test
    def test_a_raise_fault_raises_instead_of_running_the_block
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      ran = false

      assert_raises(Injected) { RogueMachines.run(:payments) { ran = true } }
      refute ran
    end

    def test_a_garble_fault_returns_the_substitute_instead_of_running_the_block
      RogueMachines.arm(:payments, fault: :garble, garbled: [], share: 1.0, expires_in: 60)
      ran = false

      assert_equal [], RogueMachines.run(:payments) { ran = true }
      refute ran
    end

    def test_a_garbled_substitute_defaults_to_nil_rather_than_the_real_value
      RogueMachines.arm(:payments, fault: :garble, share: 1.0, expires_in: 60)

      assert_nil RogueMachines.run(:payments) { :real }
    end

    def test_a_delay_fault_waits_and_then_makes_the_real_call
      RogueMachines.arm(:slow, fault: :delay, delay: 0.05, share: 1.0, expires_in: 60)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = RogueMachines.run(:slow) { :real }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :real, result
      assert_operator elapsed, :>=, 0.05
    end

    def test_an_experiment_only_reaches_the_name_it_was_armed_under
      RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)

      assert_equal :real, RogueMachines.run(:search) { :real }
      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }
    end

    def test_the_share_is_half_open_so_the_boundary_draw_makes_the_real_call
      RogueMachines.arm(:payments, fault: :raise, share: 0.1, expires_in: 60)

      draws(PER_MILLION / 10 - 1)
      assert_raises(Injected) { RogueMachines.run(:payments) { :real } }

      draws(PER_MILLION / 10)
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_an_injection_is_a_frozen_data_naming_its_fault
      RogueMachines.arm(:slow, fault: :delay, delay: 2, share: 1.0, expires_in: 60)
      now = RogueMachines.clock.now_ns
      injection = RogueMachines.registry.decide('slow', now, 0,
                                                RogueMachines.registry.generation)

      assert_kind_of Data, injection
      assert_predicate injection, :frozen?
      assert_equal %i[fault delay_ns], Injection.members
      assert_equal :delay, injection.fault
      assert_equal 2 * NS_PER_SECOND, injection.delay_ns
    end

    def test_a_fault_with_no_delay_reports_no_delay
      RogueMachines.arm(:loud, fault: :raise, share: 1.0, expires_in: 60)
      now = RogueMachines.clock.now_ns
      injection = RogueMachines.registry.decide('loud', now, 0,
                                                RogueMachines.registry.generation)

      assert_equal :raise, injection.fault
      assert_equal 0, injection.delay_ns
    end

    def test_a_seeded_random_replays_the_same_calls
      sequence = lambda do
        RogueMachines.disarm_all
        RogueMachines.random = Random.new(1234)
        RogueMachines.arm(:payments, fault: :raise, share: 0.3, expires_in: 60)
        200.times.map do
          RogueMachines.run(:payments) { :real }
        rescue Injected
          :injected
        end
      end

      assert_equal sequence.call, sequence.call
    end

    def test_a_share_of_zero_is_armed_and_reaches_nothing
      RogueMachines.arm(:payments, fault: :raise, share: 0.0, expires_in: 60)

      assert_predicate RogueMachines, :armed?
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end
  end
end
