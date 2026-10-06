#!/usr/bin/env ruby
# Check parsed uses values, including job-level reusable workflows.
require 'yaml'

def check_uses(value, path)
  case value
  when Hash
    value.each do |key, child|
      if key == 'uses'
        unless child.is_a?(String) && (child.start_with?('./') || child.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\z}))
          raise "Mutable or unsupported action reference in #{path}: #{child.inspect}"
        end
      else
        check_uses(child, path)
      end
    end
  when Array
    value.each { |child| check_uses(child, path) }
  end
end

root = File.expand_path('..', __dir__)
Dir.glob("#{root}/workflows/*.{yml,yaml}").each do |path|
  check_uses(YAML.safe_load(File.read(path), aliases: true), path)
end
puts 'All external workflow actions use immutable full commit SHAs.'
