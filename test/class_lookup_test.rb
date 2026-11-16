# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'rbconfig'

# The class of the value the extension wraps (Rogue) is fixed when it loads.
# Nothing a caller does, redefining the constant or `Object.const_get`, reaches
# a Rogue being built. Each case runs in a fresh process: the class is fixed
# once per process, at load.
class ClassLookupTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  # Runs `body` in a new Ruby; answers its last line of output.
  def isolated(body)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-e', body)
    assert status.success?, "exited #{status.exitstatus}: #{err}"
    out.lines.last&.chomp
  end

  # Bug: the class was first looked up by the runtime's own `Rogue.new`,
  # through `Object.const_get`, and one that raised hit an `unwrap` in the
  # extension: an uncatchable fatal while loading. Now the load raises
  # NameError, which a caller can rescue.
  def test_a_raising_const_get_does_not_kill_the_process
    assert_equal 'NameError', isolated(<<~RUBY)
      Object.define_singleton_method(:const_get) do |name, *rest|
        raise IOError, 'lookup ran' if name.to_s.end_with?('::Rogue')
        super(name, *rest)
      end
      begin
        require 'rogue_machines'
        puts 'loaded'
      rescue NameError => e
        puts e.class
      end
    RUBY
  end

  # Bug: an `Object.const_get` answering another class for the Rogue made
  # every Rogue, the runtime's own included, an instance of that class, so
  # the gem loaded with a runtime that could not arm. Now the load refuses.
  def test_a_const_get_answering_another_class_does_not_load
    assert_equal 'NameError', isolated(<<~RUBY)
      decoy = Class.new
      Object.define_singleton_method(:const_get) do |name, *rest|
        name.to_s.end_with?('::Rogue') ? decoy : super(name, *rest)
      end
      begin
        require 'rogue_machines'
        puts RogueMachines::Rogue.new.class
      rescue NameError => e
        puts e.class
      end
    RUBY
  end

  # After load, a redefined constant or `Object.const_get` is never
  # consulted: `new` and `dup` build the class the gem defined.
  def test_building_a_rogue_runs_no_ruby
    assert_equal '0 true true', isolated(<<~RUBY)
      require 'rogue_machines'
      original = RogueMachines::Rogue
      hits = 0
      Object.define_singleton_method(:const_get) do |*args|
        hits += 1
        super(*args)
      end
      RogueMachines.send(:remove_const, :Rogue)
      RogueMachines.const_set(:Rogue, Class.new)
      rogue = original.new
      puts [hits, rogue.instance_of?(original), rogue.dup.instance_of?(original)].join(' ')
    RUBY
  end
end
