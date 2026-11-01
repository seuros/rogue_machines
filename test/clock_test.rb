# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # A clock that parks inside the first reading taken by a thread that asked
  # to be parked, so a clock replacement can be driven to land exactly inside
  # another call's reading. Targeting a thread rather than counting readings
  # keeps the test honest when a method starts taking one more of them.
  class ParkingClock
    PARK = :rogue_machines_park

    def initialize(entered, release)
      @entered = entered
      @release = release
    end

    def now_ns
      if Thread.current[PARK]
        Thread.current[PARK] = nil
        @entered.push(:parked)
        @release.pop
      end
      DeadlineMachines::MonotonicClock.now_ns
    end
  end

  # A clock that captures its reading and then parks, so the reading really is
  # older than whatever eventually uses it.
  class StallingClock
    PARK = :rogue_machines_stall

    attr_accessor :reading

    def initialize(entered, release)
      @entered = entered
      @release = release
      @reading = 0
    end

    def now_ns
      seen = @reading
      if Thread.current[PARK]
        Thread.current[PARK] = nil
        @entered.push(:parked)
        @release.pop
      end
      seen
    end
  end

  class ClockTest < Test
    # A rendezvous with no timeout turns a broken expectation into a wedged
    # CI job rather than a red test.
    RENDEZVOUS = 10

    def setup
      super
      @entered = Queue.new
      @release = Queue.new
    end

    def parked
      @entered.pop(timeout: RENDEZVOUS) || flunk('the other thread never parked')
    end

    def finished(thread)
      thread.join(RENDEZVOUS) || flunk('the other thread never finished')
      thread.value
    end

    def test_an_arm_across_a_clock_replacement_is_bounded_by_the_incoming_clock
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      armer = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 1)
      end

      parked
      RogueMachines.clock = DeadlineMachines::TestClock.new
      @release.push(:go)

      # Its reading came from the outgoing clock, so it is re-taken rather
      # than published: one second means one second of whichever clock the
      # experiment ends up measured against.
      assert_equal :payments, finished(armer)
      assert_equal [:payments], RogueMachines.armed

      RogueMachines.clock.advance(1)

      assert_empty RogueMachines.armed
    end

    def test_a_run_in_flight_across_a_clock_replacement_retires_nothing
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      RogueMachines.arm(:old, fault: :raise, share: 1.0, expires_in: 60)
      runner = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.run(:old) { :real }
      end

      parked
      RogueMachines.clock = DeadlineMachines::TestClock.new
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0,
                                   expires_in: 300)
      @release.push(:go)
      finished(runner)

      # The parked reading came from the outgoing clock, and sweeping is
      # destructive, so acting on it would retire what was armed after it.
      assert_equal [:payments], RogueMachines.armed
      assert_equal :substitute, RogueMachines.run(:payments) { :real }
    end

    def test_a_disarm_across_a_clock_replacement_acts_on_the_incoming_clock
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      disarmer = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.disarm(:payments)
      end

      parked
      RogueMachines.clock = DeadlineMachines::TestClock.new
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0,
                                   expires_in: 300)
      @release.push(:go)

      # Re-taking the reading means it disarms what is actually there rather
      # than reporting on a clock nobody is using. Two calls racing on one
      # name is the caller's ambiguity, not this gem's.
      assert finished(disarmer)
      assert_empty RogueMachines.armed
      assert_equal :real, RogueMachines.run(:payments) { :real }
    end

    def test_a_query_in_flight_across_a_clock_replacement_keeps_the_substitute
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      RogueMachines.arm(:old, fault: :raise, share: 1.0, expires_in: 60)
      asker = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.armed
      end

      parked
      RogueMachines.clock = DeadlineMachines::TestClock.new
      RogueMachines.arm(:payments, fault: :garble, garbled: :substitute, share: 1.0,
                                   expires_in: 300)
      @release.push(:go)
      finished(asker)

      assert_equal :substitute, RogueMachines.run(:payments) { :real }
    end

    def test_an_expiry_is_measured_from_a_reading_taken_before_the_lock
      # Pinning a limitation rather than a feature. A caller's clock must not
      # run inside the lock, so the reading precedes the arming by however
      # long the clock and the lock took. Verifying afterwards was worse: it
      # reported failure while leaving the experiment armed, and its rollback
      # could retire another thread's successful arm of the same name.
      clock = StallingClock.new(@entered, @release)
      RogueMachines.clock = clock
      armer = Thread.new do
        Thread.current[StallingClock::PARK] = true
        RogueMachines.arm(:payments, fault: :raise, share: 1.0, expires_in: 60)
      end

      parked
      clock.reading = 120 * NS_PER_SECOND
      @release.push(:go)

      assert_equal :payments, finished(armer)
      assert_empty RogueMachines.armed
    end

    def test_a_name_armed_and_disarmed_during_a_call_never_pays_a_missing_payload
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      RogueMachines.arm(:keeper, fault: :raise, share: 1.0, expires_in: 600)
      runner = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.run(:brief) { :real }
      end

      parked
      RogueMachines.arm(:brief, fault: :garble, garbled: :substitute, share: 1.0,
                                expires_in: 60)
      RogueMachines.disarm(:brief)
      @release.push(:go)

      # Armed after the call began and gone before it decided: it must make
      # the real call, not return the nil that neither store knows about.
      assert_equal :real, finished(runner)
    end

    def test_a_stale_reading_retires_a_freshly_armed_experiment
      # Pinning a limitation. One reading cannot be told apart from another on
      # the same clock, so a reading held across a backwards step sweeps
      # against expiries it predates. `RogueMachines.clock=` is the supported
      # way to change clocks precisely because it cannot be got wrong.
      clock = StallingClock.new(@entered, @release)
      RogueMachines.clock = clock
      clock.reading = 5 * NS_PER_SECOND
      waiter = Thread.new do
        Thread.current[StallingClock::PARK] = true
        RogueMachines.armed
      end

      parked
      clock.reading = 0
      RogueMachines.arm(:fresh, fault: :garble, garbled: :substitute, share: 1.0, expires_in: 1)
      @release.push(:go)
      finished(waiter)

      assert_empty RogueMachines.armed
    end

    def test_a_decision_selecting_an_experiment_newer_than_the_snapshot_still_pays_it
      RogueMachines.clock = ParkingClock.new(@entered, @release)
      RogueMachines.arm(:keeper, fault: :raise, share: 1.0, expires_in: 600)
      runner = Thread.new do
        Thread.current[ParkingClock::PARK] = true
        RogueMachines.run(:late) { :real }
      end

      parked
      RogueMachines.arm(:late, fault: :garble, garbled: :substitute, share: 1.0,
                               expires_in: 60)
      @release.push(:go)

      # The decision and the payload are two reads. An arm landing between
      # them publishes an experiment the decision selects and the snapshot has
      # never heard of, so the snapshot alone would answer nil.
      assert_equal :substitute, finished(runner)
    end
  end
end
