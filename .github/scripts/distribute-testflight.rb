#!/usr/bin/env ruby
require_relative "testflight-common"

$stdout.sync = true

def distribute_testflight(client, env = ENV, sleep_for: ->(seconds) { sleep seconds })
  marketing_version = env.fetch("MARKETING_VERSION", "")
  marketing_version = marketing_version.empty? ? TestFlight.project_version : TestFlight.version(marketing_version)
  target_number = TestFlight.number(env.fetch("BUILD_NUMBER"))
  source_number = TestFlight.number(env.fetch("DISTRIBUTE_FROM_BUILD", "6"))
  catalog = TestFlight::Catalog.new(client)
  source = catalog.source_build(source_number, env["DISTRIBUTE_FROM_VERSION"])
  groups = catalog.source_groups(source)
  puts "Source tester groups: #{groups.map { |group| group.dig('attributes', 'name') }.join(', ')}"
  groups.each { |group| puts "#{group.dig('attributes', 'name')} automatically receives all builds" if group.dig("attributes", "hasAccessToAllBuilds") }
  target = nil
  24.times do |attempt|
    target = catalog.find_build(marketing_version: marketing_version, number: target_number)
    state = target&.dig("attributes", "processingState")
    puts "Build #{marketing_version} (#{target_number}): #{state || 'not yet visible'}"
    break if state == "VALID"
    raise "Build #{marketing_version} (#{target_number}) failed processing: #{state}" if %w[FAILED INVALID].include?(state)
    sleep_for.call(30) unless attempt == 23
  end
  raise "Build #{marketing_version} (#{target_number}) was not processed within 12 minutes" unless target&.dig("attributes", "processingState") == "VALID"
  target_id = target.fetch("id")
  initial = client.request("/v1/builds/#{target_id}/buildBetaDetail").fetch("data").fetch("attributes")
  if initial["internalBuildState"] == "MISSING_EXPORT_COMPLIANCE"
    raise "Export-compliance review required" unless source.dig("attributes", "usesNonExemptEncryption") == false
    client.request("/v1/builds/#{target_id}", method: :patch, body: { data: { type: "builds", id: target_id, attributes: { usesNonExemptEncryption: false } } })
    puts "Copied exempt encryption classification from build #{source_number}"
  elsif %w[PROCESSING_EXCEPTION EXPIRED].include?(initial["internalBuildState"])
    raise "Target build cannot reach testers: #{initial['internalBuildState']}"
  end
  groups.each do |group|
    id = group.fetch("id")
    next if catalog.group_build_ids(id).include?(target_id)
    next if group.dig("attributes", "hasAccessToAllBuilds")
    client.request("/v1/betaGroups/#{id}/relationships/builds", method: :post, body: { data: [{ type: "builds", id: target_id }] })
    puts "Added #{marketing_version} (#{target_number}) to #{group.dig('attributes', 'name')}"
  end
  detail = nil
  12.times do |attempt|
    missing = groups.reject { |group| catalog.group_build_ids(group.fetch("id")).include?(target_id) }
    detail = client.request("/v1/builds/#{target_id}/buildBetaDetail").fetch("data").fetch("attributes")
    states = groups.map { |group| detail.fetch(group.dig("attributes", "isInternalGroup") ? "internalBuildState" : "externalBuildState") }
    break if missing.empty? && states.all? { |state| TestFlight::READY_STATES.include?(state) }
    raise "Target build cannot reach testers: #{states.join(', ')}" if states.any? { |state| %w[PROCESSING_EXCEPTION EXPIRED].include?(state) }
    if attempt == 11
      raise "Target build is not yet available to the approved tester group: #{states.join(', ')}; retry verify-only"
    end
    sleep_for.call(30)
  end
  puts "Build #{marketing_version} (#{target_number}) internal state: #{detail['internalBuildState']}"
  puts "Build #{marketing_version} (#{target_number}) external state: #{detail['externalBuildState']}"
  puts "Build #{marketing_version} (#{target_number}) is processed and available to the approved tester groups."
  { marketing_version: marketing_version, build_number: target_number, processing: "VALID", tester_groups: groups.map { |group| group.dig("attributes", "name") }, internal_state: detail["internalBuildState"], external_state: detail["externalBuildState"] }
end

if $PROGRAM_NAME == __FILE__
  begin
    result = distribute_testflight(AppStoreConnect.new)
    puts JSON.pretty_generate(result)
    if ENV["GITHUB_OUTPUT"]
      File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts "marketing_version=#{result.fetch(:marketing_version)}" }
    end
  rescue StandardError => error
    warn "TestFlight distribution failed: #{error.message}"
    exit 1
  end
end
