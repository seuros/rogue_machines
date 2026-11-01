# frozen_string_literal: true

source 'https://rubygems.org'

# A sibling checkout when there is one, so the two move together; the
# gemspec's own runtime dependency otherwise, so a lone checkout resolves.
sibling = File.expand_path('../deadline_machines', __dir__)
gem 'deadline_machines', path: sibling if File.directory?(sibling)

gemspec

gem 'minitest', '~> 6.0'
gem 'rake', '~> 13.0'
gem 'rake-compiler', '~> 1.3'

platforms :mri do
  gem 'padded_cell', '~> 0.2'
  gem 'rbs', '~> 3.0'
end
