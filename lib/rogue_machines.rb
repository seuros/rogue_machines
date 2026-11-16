# frozen_string_literal: true

require 'deadline_machines'

require_relative 'rogue_machines/version'

# Fault injection: making a dependency fail, stall or lie on purpose.
#
# Two layers. `Rogue` and the Data values below mirror the core one for one:
# positional, Integer nanoseconds, symbols for unit variants. The module
# functions (`arm`, `run`, ...) are a process-wide runtime on top of one Rogue
# that names experiments, owns the clock and the random draw, and performs
# the fault.
#
# Every value validates at construction through the core: TypeError for the
# wrong type, RangeError for a value the core's constructor rejects.
module RogueMachines
  # The core's `Slot`: an index below EXPERIMENTS, picked by the caller.
  # Not an issued id: any in-range index names a slot.
  Slot = Data.define(:index) do
    def initialize(index:)
      super(index: RogueMachines.__send__(:__slot, index))
    end
  end

  # The core's `Fraction`: the share of calls a fault reaches, in millionths,
  # 0..PER_MILLION.
  Fraction = Data.define(:millionths) do
    def initialize(millionths:)
      super(millionths: RogueMachines.__send__(:__fraction, millionths))
    end

    # The core's `Fraction::covers`: whether `draw` (a Draw) falls in this
    # share, which is half open at its own boundary.
    def covers?(draw) = RogueMachines.__send__(:__covers, self, draw)
  end

  # The core's `Draw`: one call's random draw, in millionths, below
  # PER_MILLION.
  Draw = Data.define(:millionths) do
    def initialize(millionths:)
      super(millionths: RogueMachines.__send__(:__draw, millionths))
    end
  end

  # The core's `Fault::Delay`: wait `duration` Integer nanoseconds, then make
  # the real call. The other faults are the symbols :raise and :garble.
  Delay = Data.define(:duration) do
    def initialize(duration:)
      super(duration: RogueMachines.__send__(:__delay, duration))
    end
  end

  # The core's `Experiment`: a fault (:raise, :garble or a Delay), the
  # Fraction of calls it reaches, and the Integer nanosecond instant it
  # expires at.
  Experiment = Data.define(:fault, :fraction, :expires_at) do
    def initialize(fault:, fraction:, expires_at:)
      fault, fraction, expires_at = RogueMachines.__send__(:__experiment, fault, fraction, expires_at)
      super
    end

    # The core's `Experiment::spent`: whether this has expired by `now`
    # Integer nanoseconds, `now >= expires_at`.
    def spent?(now) = RogueMachines.__send__(:__spent, self, now)
  end

  # The core's `Decision::Inject`: do `fault` instead of the real call.
  Inject = Data.define(:fault) do
    def initialize(fault:)
      super(fault: RogueMachines.__send__(:__fault, fault))
    end
  end

  # The core's `Arming::Replaced`: the experiment the slot held before, and
  # the `garbled:` substitute the runtime held with it (any object, or nil;
  # always nil from the core mirror `Rogue`, which keeps no substitutes).
  Replaced = Data.define(:experiment, :garbled) do
    def initialize(experiment:, garbled:)
      super(experiment: RogueMachines.__send__(:__held, experiment), garbled:)
    end
  end

  # The core's `Disarming::Disarmed`: the experiment the slot held, and the
  # `garbled:` substitute the runtime removed with it (any object, or nil;
  # always nil from the core mirror `Rogue`, which keeps no substitutes).
  Disarmed = Data.define(:experiment, :garbled) do
    def initialize(experiment:, garbled:)
      super(experiment: RogueMachines.__send__(:__held, experiment), garbled:)
    end
  end
end

# Native is required: there is no pure-Ruby fallback. It validates and builds
# the Data values above, so they must exist first.
require 'rogue_machines_native/rogue_machines_native'

module RogueMachines
  private_class_method :__slot, :__fraction, :__draw, :__delay, :__experiment, :__fault, :__delay_of, :__held,
                       :__spent, :__covers

  # The core's `Fraction::NONE` and `Fraction::ALL`.
  Fraction::NONE = Fraction.new(0)
  Fraction::ALL = Fraction.new(PER_MILLION)

  # The values are final. `initialize` is where each validates, and a subclass
  # could override it, or `allocate` build an instance that never ran it:
  # subclassing raises TypeError (as subclassing Class does) and `allocate`
  # is gone. `new`, keywords, `with` and `dup` all still run the check.
  [Slot, Fraction, Draw, Delay, Experiment, Inject, Replaced, Disarmed].each do |value|
    value.singleton_class.undef_method(:allocate)
    value.define_singleton_method(:inherited) { |_| raise TypeError, "#{value} cannot be subclassed" }
  end
  # The native Rogue has no allocator; it is final too.
  Rogue.define_singleton_method(:inherited) { |_| raise TypeError, "#{Rogue} cannot be subclassed" }

  class Rogue
    # A copy, frozen when this is unless `freeze:` says otherwise.
    def clone(freeze: nil)
      copy = dup
      (freeze.nil? ? frozen? : freeze) ? copy.freeze : copy
    end
  end
end

require_relative 'rogue_machines/runtime'
