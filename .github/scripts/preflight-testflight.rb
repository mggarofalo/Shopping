#!/usr/bin/env ruby
require_relative "testflight-common"

def run_preflight(client, env = ENV, project: nil)
  project_version = project ? TestFlight.project_version(project) : TestFlight.project_version
  requested_version = env.fetch("MARKETING_VERSION", "")
  marketing_version = requested_version.empty? ? project_version : TestFlight.version(requested_version)
  if env.fetch("RELEASE_MODE", "preflight") == "upload" && marketing_version != project_version
    raise "Upload marketing version must match the clean release source"
  end
  receipt = TestFlight::Catalog.new(client).preflight(marketing_version: marketing_version,
    requested_number: env.fetch("BUILD_NUMBER", ""), source_number: env.fetch("DISTRIBUTE_FROM_BUILD", "6"),
    source_version: env["DISTRIBUTE_FROM_VERSION"])
  if env["GITHUB_OUTPUT"]
    File.open(env.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("build_number=#{receipt[:build_number]}\nmarketing_version=#{receipt[:marketing_version]}") }
  end
  receipt
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(run_preflight(AppStoreConnect.new(read_only: true)))
  rescue StandardError => error
    warn "TestFlight preflight failed: #{error.message}"
    exit 1
  end
end
