#!/usr/bin/env ruby
require "minitest/autorun"
require "yaml"
require "open3"
require_relative "audit-testflight-audience"

class AudienceAuditFixture
  attr_reader :requests
  def initialize
    @requests = []
  end
  def list(path)
    @requests << [:get, path]
    uri = URI.parse(path)
    query = URI.decode_www_form(uri.query || "").to_h
    case uri.path
    when "/v1/apps"
      [{ "id" => "shopping", "attributes" => { "bundleId" => TestFlight::BUNDLE_ID } }]
    when "/v1/builds"
      number = query.fetch("filter[version]")
      [{ "id" => "build-#{number}", "attributes" => { "version" => number, "processingState" => "VALID" } }]
    when "/v1/apps/shopping/betaGroups"
      [{ "id" => "external", "attributes" => { "name" => "Existing external fixture", "isInternalGroup" => false } }]
    when "/v1/betaGroups/external/betaTesters"
      [{ "id" => "beka", "attributes" => { "firstName" => "Beka", "email" => "private@example.invalid", "state" => "INSTALLED" } }]
    when "/v1/betaGroups/external/relationships/builds"
      [{ "id" => "build-26" }]
    when "/v1/betaAppReviewSubmissions"
      []
    else
      raise "Unexpected GET #{path}"
    end
  end
  def request(path, method: :get, body: nil)
    @requests << [method, path]
    raise "Audit attempted mutation" unless method == :get
    { "data" => { "id" => "detail", "attributes" => { "internalBuildState" => "IN_BETA_TESTING", "externalBuildState" => "READY_FOR_BETA_SUBMISSION", "autoNotifyEnabled" => false } } }
  end
end

class AudienceAuditTests < Minitest::Test
  def test_existing_group_and_tester_association_without_pii_or_mutations
    client = AudienceAuditFixture.new
    receipt = audit_testflight_audience(client)
    assert receipt[:groups].first[:includes_build_26]
    refute receipt[:groups].first[:includes_requested_build]
    assert_equal [{ id: "beka", first_name: "Beka", state: "INSTALLED" }], receipt[:groups].first[:known_testers]
    refute_includes JSON.generate(receipt), "private@example.invalid"
    assert client.requests.all? { |method, _| method == :get }
  end
  def test_protected_main_only_workflow_and_no_signing_or_extra_permissions
    workflow = YAML.safe_load(File.read(File.expand_path("../workflows/testflight-audience-audit.yml", __dir__)), aliases: true)
    assert_equal ["workflow_dispatch"], (workflow["on"] || workflow.fetch(true)).keys
    assert_equal({ "contents" => "read" }, workflow["permissions"])
    assert_equal({ "group" => "shopping-testflight", "cancel-in-progress" => false }, workflow["concurrency"])
    job = workflow["jobs"]["audit"]
    assert_equal "testflight", job["environment"]
    assert_equal "intent", job["needs"]
    assert_includes job["if"], "refs/heads/main"
    assert_equal({ "uses" => "actions/checkout@v5" }, job["steps"].first)
    refute job["steps"].last["env"].keys.any? { |key| key.match?(/PROVISIONING|CERTIFICATE|GH_TOKEN/) }
    intent = workflow["jobs"]["intent"]["steps"].first["run"]
    %w[refs/heads/main refs/heads/feature].each do |ref|
      _, _, status = Open3.capture3({ "REF" => ref }, "bash", "-c", intent)
      assert_equal(ref == "refs/heads/main", status.success?)
    end
  end
end
