#!/usr/bin/env ruby
require_relative "testflight-common"

module TestFlight
  class ExistingAudience
    def initialize(catalog, policy)
      @catalog, @client, @policy = catalog, catalog.client, policy
    end

    def groups
      approved = @policy.fetch("groups")
      raise "Audience policy must contain one internal and one external group" unless approved.length == 2 && approved.map { |group| group.fetch("internal") }.sort_by(&:to_s) == [false, true]
      all = @client.list("/v1/apps/#{@catalog.app_id}/betaGroups?limit=200")
      approved.map do |expected|
        matches = all.select { |group| group.fetch("id") == expected.fetch("id") }
        raise "Approved tester group is missing or ambiguous" unless matches.length == 1
        group = matches.first
        attributes = group.fetch("attributes")
        private_access = expected.fetch("internal") ? attributes["publicLinkEnabled"] != true : attributes["publicLinkEnabled"] == false
        unless attributes["name"] == expected.fetch("name") && attributes["isInternalGroup"] == expected.fetch("internal") && private_access
          raise "Approved tester group identity or public-link access changed"
        end
        members = @client.list("/v1/betaGroups/#{group.fetch('id')}/betaTesters?limit=200").map { |member| member.fetch("id") }.sort
        raise "Approved tester membership changed; review the audience before distribution" unless !members.empty? && members == expected.fetch("tester_ids").sort
        group
      end
    end

    def review_metadata
      locales = @client.list("/v1/apps/#{@catalog.app_id}/betaAppLocalizations?limit=200")
      unless !locales.empty? && locales.all? { |locale| !locale.dig("attributes", "description").to_s.strip.empty? }
        raise "Existing beta app descriptions are incomplete; request the missing test information"
      end
      detail = @client.request("/v1/apps/#{@catalog.app_id}/betaAppReviewDetail").fetch("data").fetch("attributes")
      required = %w[contactFirstName contactLastName contactPhone contactEmail]
      required += %w[demoAccountName demoAccountPassword] if detail["demoAccountRequired"] == true
      unless required.all? { |field| !detail[field].to_s.strip.empty? } && [true, false].include?(detail["demoAccountRequired"])
        raise "Existing beta-review contact or demo-account information is incomplete; request verified values"
      end
      true
    end
  end
end

def distribute_external_testflight(client, env = ENV, policy: nil)
  policy ||= JSON.parse(File.read(File.expand_path("../testflight-audience.json", __dir__)))
  catalog = TestFlight::Catalog.new(client)
  audience = TestFlight::ExistingAudience.new(catalog, policy)
  groups = audience.groups
  external = groups.find { |group| group.dig("attributes", "isInternalGroup") == false }
  version = env.fetch("MARKETING_VERSION", "")
  version = version.empty? ? TestFlight.project_version : TestFlight.version(version)
  number = TestFlight.number(env.fetch("BUILD_NUMBER"))
  target = catalog.find_build(marketing_version: version, number: number)
  raise "External distribution requires the exact processed build" unless target && target.dig("attributes", "processingState") == "VALID"
  id = target.fetch("id")
  raise "External distribution requires established exempt-encryption metadata" unless target.dig("attributes", "usesNonExemptEncryption") == false
  detail = client.request("/v1/builds/#{id}/buildBetaDetail").fetch("data")
  state = detail.dig("attributes", "externalBuildState")
  submissions_path = TestFlight.query("/v1/betaAppReviewSubmissions", "filter[build]" => id, "limit" => 200)
  reviews = client.list(submissions_path)
  raise "Beta review was rejected; resolve Apple's feedback before retrying" if reviews.any? { |review| review.dig("attributes", "betaReviewState") == "REJECTED" }
  unless (TestFlight::READY_STATES + %w[READY_FOR_BETA_SUBMISSION WAITING_FOR_BETA_REVIEW IN_BETA_REVIEW BETA_APPROVED]).include?(state)
    raise "Build cannot be externally distributed in state #{state}"
  end
  if state == "READY_FOR_BETA_SUBMISSION" && reviews.empty?
    blockers = catalog.pending_beta_reviews(marketing_version: version, except_build_id: id)
    unless blockers.empty?
      waiting = blockers.map { |review| "#{version} (#{review.fetch(:build_number)}): #{review.fetch(:state)}" }.join(", ")
      raise "External beta review blocked by existing review #{waiting}. Apple allows one build per version in review. Preserve that submission; retry verify-only for #{version} (#{number}) after its review completes. This build has not been submitted or assigned externally."
    end
    audience.review_metadata
  end
  if detail.dig("attributes", "autoNotifyEnabled") != true
    client.request("/v1/buildBetaDetails/#{detail.fetch('id')}", method: :patch,
      body: { data: { type: "buildBetaDetails", id: detail.fetch("id"), attributes: { autoNotifyEnabled: true } } })
  end
  if state == "READY_FOR_BETA_SUBMISSION" && reviews.empty?
    client.request("/v1/betaAppReviewSubmissions", method: :post,
      body: { data: { type: "betaAppReviewSubmissions", relationships: { build: { data: { type: "builds", id: id } } } } })
  end
  group_id = external.fetch("id")
  unless catalog.group_build_ids(group_id).include?(id)
    client.request("/v1/betaGroups/#{group_id}/relationships/builds", method: :post,
      body: { data: [{ type: "builds", id: id }] })
  end
  raise "External group assignment is not confirmed; retry verification" unless catalog.group_build_ids(group_id).include?(id)
  final = client.request("/v1/builds/#{id}/buildBetaDetail").fetch("data").fetch("attributes")
  raise "Automatic tester notification is not confirmed; retry verification" unless final["autoNotifyEnabled"] == true
  reviews = client.list(submissions_path)
  ready = TestFlight::READY_STATES.include?(final["externalBuildState"])
  pending = reviews.any? { |review| %w[WAITING_FOR_REVIEW IN_REVIEW].include?(review.dig("attributes", "betaReviewState")) }
  raise "External availability or a pending Apple review is not confirmed; retry verification" unless ready || pending
  { marketing_version: version, build_number: number, build_id: id,
    tester_group: external.dig("attributes", "name"), assigned: true, available: ready,
    external_state: final["externalBuildState"], auto_notify_enabled: true,
    reviews: reviews.map { |review| { id: review.fetch("id"), state: review.dig("attributes", "betaReviewState") } } }
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ["--preflight"]
      policy = JSON.parse(File.read(File.expand_path("../testflight-audience.json", __dir__)))
      audience = TestFlight::ExistingAudience.new(TestFlight::Catalog.new(AppStoreConnect.new(read_only: true)), policy)
      groups = audience.groups
      audience.review_metadata
      puts JSON.pretty_generate({ tester_groups: groups.map { |group| group.dig("attributes", "name") }, existing_review_metadata_complete: true, read_only: true })
    elsif ARGV.empty?
      puts JSON.pretty_generate(distribute_external_testflight(AppStoreConnect.new))
    else
      raise "Unknown external distribution mode"
    end
  rescue StandardError => error
    warn "External TestFlight distribution failed: #{error.message}"
    exit 1
  end
end
