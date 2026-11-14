# frozen_string_literal: true

module RogueMachines
  # Longest an experiment may run for, in nanoseconds. An experiment is
  # something a person is waiting on, so a day is already generous; past that
  # it is configuration, and it must be re-armed deliberately.
  LONGEST_EXPERIMENT = 24 * 60 * 60 * 1_000_000_000

  # Longest a single delay may wait, in nanoseconds. Bounds how long a stall
  # can hold a caller that has no deadline of its own.
  LONGEST_DELAY = 5 * 60 * 1_000_000_000

  # Attempts at a reading taken against the clock still installed once the
  # lock is held, before giving up on a clock replaced faster than that.
  READINGS = 100

  # The process-wide runtime: one Rogue, the names standing for its slots, and
  # the substitutes the :garble experiments return. Every store is touched only
  # under @lock; `run` reads the Rogue's gate outside it.
  #
  # Invariant: every Slot in @slots holds an experiment in @rogue (expired or
  # not), and @substitutes has keys only from @slots.
  @rogue = Rogue.new
  @slots = {}
  @substitutes = {}
  @lock = Mutex.new

  class << self
    attr_writer :random

    # Monotonic Integer nanoseconds. Delegates to deadline_machines rather
    # than memoising it, so replacing that gem's clock moves every expiry
    # with it.
    def clock
      @clock || DeadlineMachines.clock
    end

    # Installing a clock disarms everything first: every armed expiry was
    # computed against the outgoing clock, and is not an expiry against
    # another one. A reading already taken against the outgoing clock is not
    # acted on: every call that uses a reading checks, under the lock, that
    # the clock it read is still the one installed.
    def clock=(clock)
      @lock.synchronize do
        Thread.handle_interrupt(Object => :never) do
          @clock = clock
          @rogue.disarm_all
          @slots = {}
          @substitutes = {}
        end
      end
    end

    def random
      @random ||= Random.new
    end

    # A frozen copy of the runtime's Rogue, taken under the lock, for
    # reading. Not the Rogue itself: disarming that behind the names would
    # leave a name on an empty slot, which the next arm hands to a second
    # name.
    def rogue
      @lock.synchronize { @rogue.dup.freeze }
    end

    # Arms an experiment under `name`, replacing any already there.
    #
    #   RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 300 * 10**9)
    #   RogueMachines.arm(:slow, fault: RogueMachines::Delay.new(2 * 10**9), share: 1, expires_in: 60 * 10**9)
    #   RogueMachines.arm(:lies, fault: :garble, garbled: [], share: 0.5, expires_in: 60 * 10**9)
    #
    # `expires_in` is Integer nanoseconds from now and required, so no
    # experiment outlives the person who armed it. Answers what the core's
    # `arm` answered for the slot (:armed, a Replaced, :already_armed), or
    # :full, with nothing changed, when every slot holds a live experiment.
    def arm(name, fault:, share:, expires_in:, garbled: nil)
      key = named(name)
      fraction = fraction_of(share)
      checked_fault(fault)
      span = span_of(expires_in)
      payload = fault == :garble ? garbled : nil
      found = locked_reading { |now| arm_at(key, Experiment.new(fault, fraction, now + span), payload, now) }
      raise Error, "the clock was replaced #{READINGS} times while arming; nothing is armed" unless found

      found.first
    end

    # What `name`'s slot held (a Disarmed, expired or not), or :not_armed.
    # Takes no reading.
    def disarm(name)
      key = named(name)
      @lock.synchronize do
        Thread.handle_interrupt(Object => :never) do
          slot = @slots.delete(key)
          next :not_armed unless slot

          @substitutes.delete(key)
          @rogue.disarm(slot)
        end
      end
    end

    # How many experiments were held, expired or not.
    def disarm_all
      @lock.synchronize do
        Thread.handle_interrupt(Object => :never) do
          @slots = {}
          @substitutes = {}
          @rogue.disarm_all
        end
      end
    end

    # With no name, whether anything at all is live now.
    def armed?(name = nil)
      key = name.nil? ? nil : named(name).to_sym
      names = armed
      key.nil? ? names.any? : names.include?(key)
    end

    # The experiments live now. Retires the expired ones first, which
    # releases their slots and substitutes; once retired, a clock stepping
    # back cannot revive them.
    def armed
      found = locked_reading do |now|
        retire(now)
        @slots.keys.map(&:to_sym)
      end
      found ? found.first : []
    end

    # Runs the block, or the fault armed under `name` instead. Makes the real
    # call when the clock was replaced faster than a reading could be taken.
    def run(name)
      legible(name)
      return yield unless @rogue.any_armed?

      key = named(name)
      drawn = Draw.new(random.rand(PER_MILLION))
      found = locked_reading { |now| decide_at(key, now, drawn) }
      return yield unless found

      decision, payload = found.first
      return yield if decision == :pass

      perform(name, decision.fault, payload) { yield }
    end

    private

    # Arms under the lock. The room check changes nothing, so :full leaves
    # every store as it was; only then are expired experiments retired.
    #
    # The substitute is part of what is armed: the core's :already_armed
    # stands only when the stored one is equal too. A differing one is a
    # replacement, answered as the core answers a differing experiment.
    def arm_at(key, experiment, payload, now)
      return :full unless @slots.key?(key) || @rogue.vacant || @rogue.live_count(now) < @rogue.armed_count

      Thread.handle_interrupt(Object => :never) do
        retire(now)
        slot = @slots[key] || @rogue.vacant
        # Everything that runs caller code (the substitute's `==`, the answer
        # values' `new`) runs before a store changes; the Rogue's own `arm`
        # applies nothing when it raises.
        same_payload = @substitutes[key] == payload
        answer = @rogue.arm(slot, experiment)
        @slots[key] = slot
        payload.nil? ? @substitutes.delete(key) : @substitutes[key] = payload
        answer == :already_armed && !same_payload ? Replaced.new(experiment) : answer
      end
    end

    # The decision and the payload, read together under the lock. Retires
    # anything expired first, which restores the disarmed fast path.
    def decide_at(key, now, drawn)
      retire(now) if @rogue.live_count(now) < @rogue.armed_count
      slot = @slots[key]
      decision = slot ? @rogue.decide(slot, now, drawn) : :pass
      [decision, decision == :pass ? nil : @substitutes[key]]
    end

    # Empties the slots of experiments expired by `now` and drops their names
    # and substitutes. Called only under the lock with a reading against the
    # installed clock.
    def retire(now)
      Thread.handle_interrupt(Object => :never) do
        next if @rogue.sweep(now).zero?

        @slots.select! { |_, slot| @rogue.experiment(slot) }
        @substitutes.select! { |key, _| @slots.key?(key) }
      end
    end

    # `[block's answer]` for a reading taken outside the lock against the
    # clock still installed once it is held, or nil after READINGS attempts.
    # The caller's clock never runs inside the lock.
    def locked_reading
      READINGS.times do
        source = clock
        now = source.now_ns
        checked_reading(source, now)
        found = @lock.synchronize { [yield(now)] if clock.equal?(source) }
        return found if found
      end
      nil
    end

    def checked_reading(source, now)
      unless now.is_a?(Integer)
        raise TypeError, "#{source.class} returned #{now.inspect}; a reading is an Integer of nanoseconds"
      end
      raise RangeError, "#{source.class} returned #{now}; a reading is not negative" if now.negative?
    end

    # Rejects a name the runtime cannot key on, without converting it, so a
    # call site answers the same way whether or not anything is armed and the
    # disarmed `run` allocates nothing.
    def legible(name)
      text = case name
             when Symbol then name.name
             when String then name
             else raise TypeError, "an experiment name is a Symbol or a String, got #{name.class}"
             end
      raise RangeError, 'an experiment needs a name' if text.empty?
      return if text.ascii_only? || (text.encoding == Encoding::UTF_8 && text.valid_encoding?)

      raise RangeError, 'an experiment name is ASCII or valid UTF-8'
    end

    # The checked name as a frozen String key. Not `to_s`: a String subclass
    # can override it, which armed one name and reported another.
    def named(name)
      legible(name)
      name.is_a?(Symbol) ? name.name : -String.new(name)
    end

    # A Fraction as given, or a Numeric share of a whole rounded to
    # millionths. A share too small to express is refused rather than armed
    # as nothing.
    def fraction_of(share)
      return share if share.is_a?(Fraction)
      unless share.is_a?(Numeric) && share.real?
        raise TypeError, "share is a Fraction or a real Numeric, got #{share.class}"
      end

      raise RangeError, "share is between 0 and 1, got #{share}" unless share.finite? && share.between?(0, 1)

      millionths = (share * PER_MILLION).round
      raise RangeError, "share of #{share} is below one millionth" if millionths.zero? && share.positive?

      Fraction.new(millionths)
    end

    def checked_fault(fault)
      case fault
      when :raise, :garble then nil
      when Delay
        return if fault.duration.between?(1, LONGEST_DELAY)

        raise RangeError, "a delay is 1..#{LONGEST_DELAY} nanoseconds, got #{fault.duration}"
      when Symbol then raise RangeError, "fault is :raise, :garble or a Delay, got #{fault.inspect}"
      else raise TypeError, "fault is :raise, :garble or a Delay, got #{fault.class}"
      end
    end

    def span_of(expires_in)
      raise TypeError, 'expires_in is an Integer of nanoseconds' unless expires_in.is_a?(Integer)
      return expires_in if expires_in.between?(1, LONGEST_EXPERIMENT)

      raise RangeError, "expires_in is 1..#{LONGEST_EXPERIMENT} nanoseconds, got #{expires_in}"
    end

    def perform(name, fault, payload)
      case fault
      when :raise then raise Injected, "#{name} is armed to raise"
      when :garble then payload
      when Delay
        stall(fault.duration)
        yield
      end
    end

    # Spends the delay against the caller's deadline rather than past it, so a
    # slow dependency trips the timeout that was already there.
    def stall(delay_ns)
      DeadlineMachines.check!
      seconds = DeadlineMachines.clamp_sleep(delay_ns.fdiv(1_000_000_000))
      sleep(seconds) if seconds.positive?
      DeadlineMachines.check!
    end
  end
end
