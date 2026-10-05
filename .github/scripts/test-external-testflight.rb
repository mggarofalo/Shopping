#!/usr/bin/env ruby
require "minitest/autorun"
require_relative "external-testflight"

class ExternalFixture
  attr_accessor :groups, :members, :reviews, :state, :notify, :assigned, :metadata, :description, :processing, :sibling_reviews, :sibling_version
  attr_reader :writes
  def initialize
    @groups = [group("home", "Garofalo Home", true), group("external", "Fixture Beka group", false)]
    @members = { "home" => ["michael"], "external" => ["beka"] }
    @reviews, @writes = [], []
    @sibling_reviews, @sibling_version = [], "1.5.0"
    @state, @notify, @assigned, @processing = "READY_FOR_BETA_SUBMISSION", false, false, "VALID"
    @metadata = { "contactFirstName" => "Existing", "contactLastName" => "Contact", "contactPhone" => "existing", "contactEmail" => "existing", "demoAccountRequired" => false }
    @description = "Existing approved beta app description"
  end
  def group(id, name, internal)
    { "id" => id, "attributes" => { "name" => name, "isInternalGroup" => internal, "publicLinkEnabled" => false } }
  end
  def list(path)
    uri = URI.parse(path)
    case uri.path
    when "/v1/apps" then [{ "id" => "shopping", "attributes" => { "bundleId" => TestFlight::BUNDLE_ID } }]
    when "/v1/apps/shopping/betaGroups" then @groups
    when %r{\A/v1/betaGroups/([^/]+)/betaTesters\z} then @members.fetch($1).map { |id| { "id" => id } }
    when "/v1/builds"
      query = URI.decode_www_form(uri.query).to_h
      raise "Wrong build identity" unless [nil, "29"].include?(query["filter[version]"]) && query["filter[preReleaseVersion.version]"] == "1.5.0" && query["filter[preReleaseVersion.platform]"] == "IOS"
      target = { "id" => "target", "attributes" => { "version" => "29", "processingState" => @processing, "usesNonExemptEncryption" => false } }
      return [target] if query["filter[version]"] || @sibling_version != query["filter[preReleaseVersion.version]"]
      [target, { "id" => "sibling", "attributes" => { "version" => "28" } }]
    when "/v1/betaAppReviewSubmissions"
      build_id = URI.decode_www_form(uri.query).to_h.fetch("filter[build]")
      build_id == "target" ? @reviews : @sibling_reviews
    when "/v1/apps/shopping/betaAppLocalizations" then [{ "attributes" => { "description" => @description } }]
    when "/v1/betaGroups/external/relationships/builds" then @assigned ? [{ "id" => "target" }] : []
    else raise "Unexpected GET #{path}"
    end
  end
  def request(path, method: :get, body: nil)
    if method == :get
      return { "data" => { "id" => "detail", "attributes" => { "externalBuildState" => @state, "autoNotifyEnabled" => @notify } } } if path == "/v1/builds/target/buildBetaDetail"
      return { "data" => { "attributes" => @metadata } } if path == "/v1/apps/shopping/betaAppReviewDetail"
      raise "Unexpected GET #{path}"
    end
    @writes << [method, path, body]
    case [method, path]
    when [:patch, "/v1/buildBetaDetails/detail"]
      raise "Unexpected notification payload" unless body == { data: { type: "buildBetaDetails", id: "detail", attributes: { autoNotifyEnabled: true } } }
      @notify = true
    when [:post, "/v1/betaAppReviewSubmissions"]
      raise "Wrong submitted build" unless body.dig(:data, :relationships, :build, :data) == { type: "builds", id: "target" }
      @reviews = [{ "id" => "review", "attributes" => { "betaReviewState" => "WAITING_FOR_REVIEW" } }]
      @state = "WAITING_FOR_BETA_REVIEW"
    when [:post, "/v1/betaGroups/external/relationships/builds"]
      raise "Wrong assigned build" unless body == { data: [{ type: "builds", id: "target" }] }
      @assigned = true
    else raise "Unexpected mutation #{path}"
    end
    {}
  end
end

class ExternalDistributionTests < Minitest::Test
  def setup
    @api = ExternalFixture.new
    @policy = { "groups" => [{ "id" => "home", "name" => "Garofalo Home", "internal" => true, "tester_ids" => ["michael"] }, { "id" => "external", "name" => "Fixture Beka group", "internal" => false, "tester_ids" => ["beka"] }] }
  end
  def distribute
    distribute_external_testflight(@api, { "BUILD_NUMBER" => "29", "MARKETING_VERSION" => "1.5.0" }, policy: @policy)
  end
  def test_submission_before_assignment_and_pending_is_not_availability
    receipt = distribute
    assert_equal [[:patch, "/v1/buildBetaDetails/detail"], [:post, "/v1/betaAppReviewSubmissions"], [:post, "/v1/betaGroups/external/relationships/builds"]], @api.writes.map { |write| write.first(2) }
    assert receipt[:assigned]
    refute receipt[:available]
    assert receipt[:auto_notify_enabled]
    assert_equal "WAITING_FOR_REVIEW", receipt[:reviews].first[:state]
    first_writes = @api.writes.dup
    distribute
    assert_equal first_writes, @api.writes, "Retry must not resubmit or reassign"
  end
  def test_already_approved_available_build_needs_no_new_submission
    @api.state, @api.notify, @api.assigned = "IN_BETA_TESTING", true, true
    assert distribute[:available]
    assert_empty @api.writes
  end
  def test_pending_same_version_review_blocks_before_any_write_and_preserves_submission
    %w[WAITING_FOR_REVIEW IN_REVIEW].each do |state|
      setup
      @api.sibling_reviews = [{ "id" => "existing-review", "attributes" => { "betaReviewState" => state } }]
      existing = Marshal.dump(@api.sibling_reviews)
      message = assert_raises(RuntimeError) { distribute }.message
      assert_includes message, "1.5.0 (28): #{state}"
      assert_includes message, "retry verify-only for 1.5.0 (29)"
      assert_empty @api.writes
      assert_equal existing, Marshal.dump(@api.sibling_reviews)
      refute @api.assigned
    end
  end
  def test_completed_sibling_review_allows_new_submission
    @api.sibling_reviews = [{ "id" => "existing-review", "attributes" => { "betaReviewState" => "APPROVED" } }]
    assert distribute[:assigned]
    assert_equal "APPROVED", @api.sibling_reviews.first.dig("attributes", "betaReviewState")
  end
  def test_pending_review_for_another_version_does_not_block
    @api.sibling_version = "1.4.9"
    @api.sibling_reviews = [{ "id" => "other-version-review", "attributes" => { "betaReviewState" => "WAITING_FOR_REVIEW" } }]
    assert distribute[:assigned]
  end
  def test_existing_target_review_is_reused_without_resubmitting
    @api.state, @api.notify = "WAITING_FOR_BETA_REVIEW", true
    @api.reviews = [{ "id" => "target-review", "attributes" => { "betaReviewState" => "WAITING_FOR_REVIEW" } }]
    @api.sibling_reviews = [{ "id" => "sibling-review", "attributes" => { "betaReviewState" => "WAITING_FOR_REVIEW" } }]
    receipt = distribute
    assert receipt[:assigned]
    refute receipt[:available]
    assert_equal [[:post, "/v1/betaGroups/external/relationships/builds"]], @api.writes.map { |write| write.first(2) }
  end
  def test_audience_drift_public_access_and_identity_fail_before_any_write
    changes = [-> { @api.members["external"] << "someone-else" }, -> { @api.groups.last["attributes"]["publicLinkEnabled"] = true }, -> { @api.groups.last["attributes"]["publicLinkEnabled"] = nil }, -> { @api.groups.last["attributes"]["name"] = "Renamed" }, -> { @api.groups.last["attributes"]["isInternalGroup"] = true }, -> { @api.groups.pop }]
    changes.each do |change|
      setup
      change.call
      assert_raises(RuntimeError) { distribute }
      assert_empty @api.writes
    end
  end
  def test_missing_existing_metadata_never_invents_answers_or_submits
    @api.description = ""
    assert_raises(RuntimeError) { distribute }
    assert_empty @api.writes
    @api.description = "Existing description"
    @api.metadata["contactPhone"] = ""
    assert_raises(RuntimeError) { distribute }
    assert_empty @api.writes
    @api.metadata["contactPhone"] = "Existing"
    @api.metadata["demoAccountRequired"] = true
    assert_raises(RuntimeError) { distribute }
    assert_empty @api.writes
  end
  def test_rejected_and_unprocessed_builds_are_actionable_blockers
    @api.reviews = [{ "id" => "review", "attributes" => { "betaReviewState" => "REJECTED" } }]
    assert_match(/rejected/, assert_raises(RuntimeError) { distribute }.message)
    assert_empty @api.writes
    @api.reviews = []
    @api.processing = "PROCESSING"
    assert_raises(RuntimeError) { distribute }
    assert_empty @api.writes
  end
end
