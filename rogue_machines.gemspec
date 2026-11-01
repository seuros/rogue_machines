# frozen_string_literal: true

require_relative 'lib/rogue_machines/version'

Gem::Specification.new do |spec|
  spec.name = 'rogue_machines'
  spec.version = RogueMachines::VERSION
  spec.authors = ['Abdelkader Boudih']
  spec.email = ['oss@seuros.com']

  spec.summary = 'Fault injection and chaos engineering for Ruby'
  spec.description = 'Fault injection for chaos engineering: arms a named experiment that makes a ' \
                     'dependency fail, stall or lie for a share of calls, so the breakers, retries and ' \
                     'budgets around it can be shown to work. Bound to Ruby from the zero-dependency ' \
                     'rogue-machines crate. Disarmed by default, and every experiment carries an expiry ' \
                     'it cannot outlive.'
  spec.homepage = 'https://github.com/seuros/rogue_machines'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['cargo_crate_name'] = 'rogue_machines_native'
  spec.metadata['cargo_manifest_path'] = 'ext/rogue_machines_native/ffi/Cargo.toml'

  spec.files = Dir.glob(%w[
                          lib/**/*.rb
                          sig/**/*.rbs
                          ext/**/*.{rb,rs,toml}
                          Cargo.toml
                          Cargo.lock
                          README.md
                          CHANGELOG.md
                          LICENSE.txt
                        ]).select { |path| File.exist?(path) }
                   .reject { |path| path =~ %r{/tests(/|\.rs\z)} }
  spec.require_paths = ['lib']
  spec.extensions = ['ext/rogue_machines_native/extconf.rb']

  spec.add_dependency 'deadline_machines', '>= 0.1.0'

  # Not a development dependency: `spec.extensions` means a source install
  # runs extconf.rb, which requires rb_sys/mkmf, and RubyGems clears GEM_PATH
  # while building. Without this the build only works where rb_sys happens to
  # be installed globally.
  spec.add_dependency 'rb_sys', '~> 0.9'
end
