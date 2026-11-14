# frozen_string_literal: true

require 'test_helper'

module RogueMachines
  # The native boundary is the authority: sealing stops accidents, a value
  # forged past it is refused before it reaches the core, and an answer built
  # by Ruby code never loses or half-applies the call it answers.
  class BoundaryTest < Minitest::Test
    VALUES = [Slot, Fraction, Draw, Delay, Experiment, Inject, Replaced, Disarmed].freeze

    # Ruby binds a named subclass's constant before `inherited` raises, so the
    # constant leaks; it is still refused wherever the binding reads it.
    module Forged; end

    def forge(value, name)
      return Forged.const_get(name, false) if Forged.const_defined?(name, false)

      assert_raises(TypeError) { Forged.module_eval("class #{name} < #{value}; end", __FILE__, __LINE__) }
      forged = Forged.const_get(name, false)
      forged.define_method(:initialize) { |**kw| Data.instance_method(:initialize).bind_call(self, **kw) }
      forged
    end

    def setup
      @rogue = Rogue.new
    end

    def raising(expires_at) = Experiment.new(:raise, Fraction::ALL, expires_at)

    def state = [@rogue.armed_count, (0...4).map { |index| @rogue.experiment(Slot.new(index)) }]

    def test_every_value_and_the_rogue_are_sealed_against_anonymous_and_named_subclasses
      (VALUES + [Rogue]).each do |value|
        assert_raises(TypeError) { Class.new(value) }
        forged = forge(value, "Sealed#{value.name.split('::').last}")

        assert_operator forged, :<, value, 'the constant leaks: Ruby binds it before inherited raises'
      end
    end

    def test_a_forged_subclass_value_is_a_type_error
      slot = forge(Slot, 'Slot').new(index: EXPERIMENTS + 3)
      fraction = forge(Fraction, 'Fraction').new(millionths: PER_MILLION + 1)
      draw = forge(Draw, 'Draw').new(millionths: PER_MILLION)
      experiment = forge(Experiment, 'Experiment').new(fault: :bogus, fraction: Fraction::ALL, expires_at: -1)

      assert_raises(TypeError) { @rogue.arm(slot, raising(1)) }
      assert_raises(TypeError) { @rogue.arm(Slot.new(0), experiment) }
      assert_raises(TypeError) { @rogue.experiment(slot) }
      assert_raises(TypeError) { @rogue.decide(Slot.new(0), 0, draw) }
      assert_raises(TypeError) { Experiment.new(:raise, fraction, 1) }
      assert_equal 0, @rogue.armed_count
    end

    # A singleton class opened on a genuine value does not change what it is.
    def test_an_opened_singleton_class_is_still_the_gems_value
      slot = Slot.new(0).tap(&:singleton_class)
      fraction = Fraction::ALL.dup.tap(&:singleton_class)
      delay = Delay.new(5).tap(&:singleton_class)
      experiment = Experiment.new(delay, fraction, 100).tap(&:singleton_class)

      assert_equal :armed, @rogue.arm(slot, experiment)
      assert_equal Inject.new(Delay.new(5)), @rogue.decide(slot, 0, Draw.new(0).tap(&:singleton_class))
    end

    def test_a_marshal_edited_value_is_revalidated_into_a_range_error
      slot = Marshal.load(Marshal.dump(Slot.new(1)).sub("i\x06".b, "i\x02\xFF\x00".b))
      fraction = Marshal.load(Marshal.dump(Fraction.new(5)).sub("i\x0A".b, "i\x04\x40\x42\x0F\x01".b))

      assert_instance_of Slot, slot
      assert_equal 255, slot.index
      assert_raises(RangeError) { @rogue.arm(slot, raising(1)) }
      assert_raises(RangeError) { @rogue.experiment(slot) }
      assert_operator fraction.millionths, :>, PER_MILLION
      assert_raises(RangeError) { Experiment.new(:raise, fraction, 1) }
      assert_raises(RangeError) { fraction.covers?(Draw.new(0)) }
      assert_equal 0, @rogue.armed_count
    end

    # Fields are read from the struct itself: a redefined reader, one that
    # would lie or re-enter the Rogue alike, is never called.
    def test_a_redefined_reader_is_ignored
      @rogue.arm(Slot.new(0), raising(100))
      rogue = @rogue
      lying = lambda do |name|
        lambda do
          rogue.disarm_all
          raise "#{name} reader called"
        end
      end
      readers = { Slot => %i[index], Draw => %i[millionths], Fraction => %i[millionths],
                  Delay => %i[duration], Experiment => %i[fault fraction expires_at] }
      redefined(readers, lying) do
        assert_equal raising(100), @rogue.experiment(Slot.new(0))
        assert_equal Inject.new(:raise), @rogue.decide(Slot.new(0), 0, Draw.new(0))
        assert_equal :armed, @rogue.arm(Slot.new(1), Experiment.new(Delay.new(5), Fraction.new(7), 100))
        assert Fraction::ALL.covers?(Draw.new(0))
        refute raising(100).spent?(99)
      end
      assert_equal 2, @rogue.armed_count
    end

    def test_an_answer_whose_new_raises_applies_nothing
      @rogue.arm(Slot.new(0), raising(100))
      before = state

      answering(Replaced, -> { raise IOError }) { assert_raises(IOError) { @rogue.arm(Slot.new(0), raising(7)) } }
      answering(Disarmed, -> { raise IOError }) { assert_raises(IOError) { @rogue.disarm(Slot.new(0)) } }
      assert_equal before, state
    end

    def test_an_answer_whose_new_re_enters_raises_and_applies_nothing
      @rogue.arm(Slot.new(0), raising(100))
      reenter = -> { @rogue.arm(Slot.new(1), raising(5)) }

      answering(Replaced, reenter) { assert_raises(RuntimeError) { @rogue.arm(Slot.new(0), raising(7)) } }
      assert_equal [raising(100), raising(5)], [@rogue.experiment(Slot.new(0)), @rogue.experiment(Slot.new(1))]

      answering(Disarmed, -> { @rogue.disarm_all }) { assert_raises(RuntimeError) { @rogue.disarm(Slot.new(0)) } }
      assert_equal 0, @rogue.armed_count
    end

    def test_an_answer_whose_new_freezes_the_rogue_raises_and_applies_nothing
      @rogue.arm(Slot.new(0), raising(100))
      before = state

      answering(Disarmed, -> { @rogue.freeze }) { assert_raises(FrozenError) { @rogue.disarm(Slot.new(0)) } }
      assert_equal before, state

      @rogue = Rogue.new
      @rogue.arm(Slot.new(0), raising(100))
      before = state

      answering(Replaced, -> { @rogue.freeze }) { assert_raises(FrozenError) { @rogue.arm(Slot.new(0), raising(7)) } }
      assert_equal before, state
    end

    def test_classes_held_by_the_binding_survive_gc_compaction
      @rogue.arm(Slot.new(0), raising(100))
      # Compacting moves every unpinned object: a class the binding holds
      # unpinned would be a dangling reference and the next build would crash.
      GC.verify_compaction_references(expand_heap: true, toward: :empty)

      assert_equal raising(100), @rogue.experiment(Slot.new(0))
      assert_instance_of Disarmed, @rogue.disarm(Slot.new(0))
    end

    private

    # Runs the block with every listed reader replaced by `body.(name)`.
    def redefined(readers, body)
      readers.each do |klass, names|
        names.each do |name|
          klass.alias_method(:"__real_#{name}", name)
          klass.define_method(name, &body.(name))
        end
      end
      yield
    ensure
      readers.each do |klass, names|
        names.each do |name|
          klass.alias_method(name, :"__real_#{name}")
          klass.remove_method(:"__real_#{name}")
        end
      end
    end

    # Runs the block with `answer.new` calling `side` first.
    def answering(answer, side)
      original = answer.method(:new)
      answer.define_singleton_method(:new) do |*args, **kw|
        side.call
        original.call(*args, **kw)
      end
      yield
    ensure
      answer.define_singleton_method(:new, original)
    end
  end
end
