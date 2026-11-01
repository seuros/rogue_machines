# frozen_string_literal: true

require 'deadline_machines'

require_relative 'rogue_machines/version'

# Rogue, Injection, Error and Injected are defined by the native extension;
# there is no pure-Ruby implementation to fall back to.
require 'rogue_machines_native/rogue_machines_native'

# Fault injection: making a dependency fail, stall or lie on purpose.
#
# Disarmed is the default. `run` costs one native call that reads one word
# until something is armed.
module RogueMachines
  # Attempts at one consistent reading before giving up on a clock that is
  # being replaced faster than it can be read.
  READINGS = 100

  @registry = Rogue.new
  @substitutes = {}.freeze
  @lock = Mutex.new

  class << self
    attr_writer :random

    # Monotonic nanoseconds. Delegates to deadline_machines rather than
    # memoising it, so replacing that gem's clock moves every expiry with it.
    def clock
      @clock || DeadlineMachines.clock
    end

    # Installing a clock disarms everything first. Every armed expiry was
    # computed against the outgoing clock, and an expiry measured against a
    # clock it did not come from is not an expiry.
    #
    # It also starts a generation, so a reading already taken against the
    # outgoing clock is refused rather than compared against expiries it has
    # no relation to. `sweep` is destructive, so such a reading would retire
    # experiments armed after the swap.
    def clock=(clock)
      @lock.synchronize do
        # The native call goes last here, against the rule the other two-store
        # writes follow, because this order is observable: `reading` is
        # lock-free, and bumping the generation first would pair an outgoing
        # reading with the incoming generation, which every consumer accepts.
        Thread.handle_interrupt(Object => :never) do
          @substitutes = {}.freeze
          @clock = clock
          registry.invalidate
        end
      end
    end

    def random
      @random ||= Random.new
    end

    def registry
      @registry
    end

    # Arms an experiment under `name`, replacing any already there.
    #
    #   RogueMachines.arm(:payments, fault: :raise, share: 0.01, expires_in: 300)
    #   RogueMachines.arm(:slow, fault: :delay, delay: 2, share: 1.0, expires_in: 60)
    #   RogueMachines.arm(:lies, fault: :garble, garbled: [], share: 0.5, expires_in: 60)
    #
    # `expires_in` is required and counts from now, so no experiment outlives
    # the person who armed it.
    def arm(name, fault:, share:, expires_in:, delay: nil, garbled: nil)
      key = named(name)

      # The reading is taken before the lock so that a caller's clock never
      # runs inside it, which means the expiry is measured from slightly
      # before the arming. See "The clock is deadline_machines'" in the README.
      pair = reading
      unless pair
        raise Error, "the clock was replaced #{READINGS} times while taking one reading; " \
                     'nothing is armed'
      end

      now, age = pair
      options = { fault: fault.to_s, share: Float(share), expires_in: Float(expires_in),
                  now_ns: now, generation: age }
      options[:delay] = Float(delay) if delay

      @lock.synchronize do
        # Two stores. An interrupt landing between them would leave an armed
        # garble with nothing to return for the rest of its life, and nothing
        # repairs that, because publishing only ever removes keys.
        Thread.handle_interrupt(Object => :never) do
          registry.arm(key, **options)
          payload = options[:fault] == 'garble' ? garbled : nil
          publish(substitutes.merge(key => payload), registry.armed(now, age))
        end
      end
      name
    end

    # Reports whether `name` was still running, which an experiment that
    # expired on its own is not.
    #
    # The substitute goes first: a call landing between the two sees a garble
    # with nothing to return rather than the real value it was armed against.
    def disarm(name)
      key = named(name)
      pair = reading
      return false unless pair

      now, age = pair
      @lock.synchronize do
        # A reading from a replaced clock must not drop a substitute belonging
        # to the generation that replaced it.
        break false unless registry.generation == age

        # The native call validates its reading and can raise, so it goes
        # first: nothing is mutated unless it succeeds. Ordering no longer
        # matters to a reader, since a decision and its payload are read
        # under this same lock.
        Thread.handle_interrupt(Object => :never) do
          was_running = registry.disarm(key, now, age)
          @substitutes = substitutes.except(key).freeze
          was_running
        end
      end
    end

    def disarm_all
      @lock.synchronize do
        Thread.handle_interrupt(Object => :never) do
          registry.disarm_all
          @substitutes = {}.freeze
        end
      end
    end

    # With no name, whether anything at all is armed. Asked through the name
    # list rather than the gate `run` reads, because the gate only drops an
    # expired experiment when something next decides.
    def armed?(name = nil)
      names = running
      return names.any? if name.nil?

      names.include?(named(name))
    end

    # The experiments still running, which excludes any that has expired.
    def armed
      running.map(&:to_sym)
    end

    # Runs the block, or the fault armed under `name` instead.
    def run(name)
      check(name)
      unless registry.any_armed?
        release unless substitutes.empty?
        return yield
      end

      key = named(name)
      pair = reading
      return yield unless pair

      now, age = pair
      drawn = random.rand(PER_MILLION)

      # The decision and the payload live in different stores, so reading them
      # one after the other is wrong in both orders: a name published between
      # the two is in the decision and not the table, and one retired between
      # them is in the table and not the decision. They are read together.
      # Nothing caller-supplied runs inside the lock, since the clock and the
      # draw are already taken.
      injection, payload = @lock.synchronize do
        found = registry.decide(key, now, drawn, age)
        [found, found && substitutes[key]]
      end
      reconcile(now, age)
      return yield unless injection

      case injection.fault
      when :raise then raise Injected, "#{name} is armed to raise"
      when :garble then payload
      when :delay
        stall(injection.delay_ns)
        yield
      end
    end

    private

    def substitutes
      @substitutes
    end

    # A reading and the generation it belongs to.
    #
    # The generation is read on both sides of the reading. Reading it only
    # afterwards would adopt the new one and hand a stale reading to a
    # destructive sweep; reading it only before would pair an outgoing
    # reading with the incoming generation, which every consumer accepts. The
    # pair cannot be sampled in one step, so a change means retry.
    def reading
      READINGS.times do
        age = registry.generation
        now = clock.now_ns
        unless now.is_a?(Integer) && !now.negative?
          raise Error, "#{clock.class} returned #{now.inspect}; a reading must be a " \
                       'non-negative Integer of nanoseconds'
        end
        return [now, age] if registry.generation == age
      end
      nil
    end

    # Rejects a name the native table could not key on, without converting it,
    # so a call site answers the same way whether or not anything is armed.
    def check(name)
      case name
      when Symbol then legible(name.name)
      when String then legible(name)
      else raise ArgumentError, "an experiment name must be a Symbol or a String, got #{name.class}"
      end
    end

    def legible(name)
      raise ArgumentError, 'an experiment needs a name' if name.empty?
      return if name.ascii_only?
      return if name.encoding == Encoding::UTF_8 && name.valid_encoding?
      raise ArgumentError, "an experiment name must be valid UTF-8, got #{name.encoding}" \
        unless name.encoding == Encoding::UTF_8

      raise ArgumentError, 'an experiment name holds bytes that are not valid UTF-8'
    end

    # The checked name, as something the native table can key on. Not `to_s`:
    # a String subclass can override it, which armed one name and reported
    # another.
    def named(name)
      check(name)
      name.is_a?(Symbol) ? name.name : name
    end

    # The names still running, releasing the substitutes of everything that is
    # not.
    def running
      pair = reading
      return [] unless pair

      now, age = pair
      @lock.synchronize do
        # A reading from a replaced clock lists nothing, and must not be used
        # to prune: publishing against an empty list would wipe the table.
        break [] unless registry.generation == age

        names = registry.armed(now, age)
        publish(substitutes, names)
        names
      end
    end

    # Releases the substitutes of anything no longer running, so one armed
    # experiment holding the gate open cannot keep another's substitute, and
    # the caller's object, alive until the next `arm`.
    def reconcile(now_ns, age)
      return if substitutes.size <= registry.armed_count(now_ns, age)

      @lock.synchronize do
        publish(substitutes, registry.armed(now_ns, age)) if registry.generation == age
      end
    end

    # Only if nothing is armed once the lock is held. The gate `run` reads is
    # sampled before it, so an `arm` landing in between would otherwise have
    # its just-published substitute discarded, leaving an armed garble with
    # nothing to return for the rest of its life.
    def release
      @lock.synchronize { @substitutes = {}.freeze unless registry.any_armed? }
    end

    # Replaces the table with the entries `names` still covers, in one
    # assignment.
    def publish(table, names)
      @substitutes = table.slice(*names).freeze
    end

    # Spends the delay against the caller's deadline rather than past it, so a
    # slow dependency trips the timeout that was already there.
    def stall(delay_ns)
      DeadlineMachines.check!
      seconds = DeadlineMachines.clamp_sleep(delay_ns.fdiv(NS_PER_SECOND))
      sleep(seconds) if seconds.positive?
      DeadlineMachines.check!
    end
  end
end
