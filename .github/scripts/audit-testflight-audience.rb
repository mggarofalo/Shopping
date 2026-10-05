#!/usr/bin/env ruby
require_relative "testflight-common"

# A protected, GET-only investigation. Never emit tester emails, contact details,
# authentication material, public-link URLs or review/demo-account credentials.
def audit_testflight_audience(client, env = ENV)
  catalog = TestFlight::Catalog.new(client)
  version = TestFlight.version(env.fetch("MARKETING_VERSION", "1.5.0"))
  number = TestFlight.number(env.fetch("BUILD_NUMBER", "29"))
  target = catalog.find_build(marketing_version: version, number: number)
  raise "Requested build is missing" unless target
  prior = catalog.source_build("26", "1.3.5")
  groups = client.list("/v1/apps/#{catalog.app_id}/betaGroups?limit=200").map do |group|
    id = group.fetch("id")
    members = client.list("/v1/betaGroups/#{id}/betaTesters?limit=200")
    builds = catalog.group_build_ids(id)
    known = members.map do |member|
      name = member.dig("attributes", "firstName").to_s
      next unless %w[michael beka].include?(name.downcase)
      { id: member.fetch("id"), first_name: name, state: member.dig("attributes", "state") }
    end.compact
    { id: id, name: group.dig("attributes", "name"), internal: group.dig("attributes", "isInternalGroup"),
      automatic_all_builds: group.dig("attributes", "hasAccessToAllBuilds"), public_link_enabled: group.dig("attributes", "publicLinkEnabled"),
      tester_count: members.length, tester_ids: members.map { |member| member.fetch("id") }.sort,
      known_testers: known, includes_build_26: builds.include?(prior.fetch("id")), includes_requested_build: builds.include?(target.fetch("id")) }
  end
  detail = client.request("/v1/builds/#{target.fetch('id')}/buildBetaDetail").fetch("data")
  submissions = client.list(TestFlight.query("/v1/betaAppReviewSubmissions", "filter[build]" => target.fetch("id"), "limit" => 200))
  { marketing_version: version, build_number: number, build_id: target.fetch("id"),
    processing: target.dig("attributes", "processingState"), internal_state: detail.dig("attributes", "internalBuildState"),
    external_state: detail.dig("attributes", "externalBuildState"), beta_detail_id: detail.fetch("id"),
    auto_notify_enabled: detail.dig("attributes", "autoNotifyEnabled"),
    reviews: submissions.map { |review| { id: review.fetch("id"), state: review.dig("attributes", "betaReviewState") } },
    same_version_pending_reviews: catalog.pending_beta_reviews(marketing_version: version, except_build_id: target.fetch("id")),
    groups: groups, read_only: true }
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(audit_testflight_audience(AppStoreConnect.new(read_only: true)))
  rescue StandardError => error
    warn "Audience audit failed: #{error.message}"
    exit 1
  end
end
