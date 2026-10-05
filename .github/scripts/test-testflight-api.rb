#!/usr/bin/env ruby
require "minitest/autorun"
require "minitest/mock"
require_relative "preflight-testflight"
require_relative "distribute-testflight"

class FixtureASC
  attr_accessor :inventory, :groups, :membership, :detail, :requests
  def initialize
    @inventory = [build("source", "1.0.0", "6"), build("prior", "1.3.5", "26"), build("target", "1.4.0", "27")]
    @groups = [{ "id" => "home", "attributes" => { "name" => "Garofalo Home", "isInternalGroup" => true, "hasAccessToAllBuilds" => true } }]
    @membership = %w[source prior target]
    @detail = { "internalBuildState" => "IN_BETA_TESTING", "externalBuildState" => "READY_FOR_BETA_SUBMISSION" }
    @requests = []
  end
  def build(id, marketing, number, state = "VALID")
    { "id" => id, "attributes" => { "version" => number, "processingState" => state, "usesNonExemptEncryption" => false }, "relationships" => { "preReleaseVersion" => { "data" => { "id" => marketing } } } }
  end
  def list(path)
    @requests << [:get, path]
    uri = URI.parse(path)
    query = URI.decode_www_form(uri.query || "").to_h
    case uri.path
    when "/v1/apps"
      [{ "id" => "shopping", "attributes" => { "bundleId" => TestFlight::BUNDLE_ID } }]
    when "/v1/builds"
      raise "Missing IOS filter" unless query["filter[preReleaseVersion.platform]"] == "IOS"
      @inventory.select { |build| (!query["filter[version]"] || build.dig("attributes", "version") == query["filter[version]"]) && (!query["filter[preReleaseVersion.version]"] || build.dig("relationships", "preReleaseVersion", "data", "id") == query["filter[preReleaseVersion.version]"]) }
    when "/v1/preReleaseVersions"
      @inventory.map { |build| build.dig("relationships", "preReleaseVersion", "data", "id") }.uniq.map { |version| { "id" => version, "attributes" => { "version" => version } } }
    when "/v1/apps/shopping/betaGroups"
      @groups
    when "/v1/betaGroups/home/relationships/builds"
      @membership.map { |id| { "id" => id } }
    else
      raise "Unexpected fixture GET: #{path}"
    end
  end
  def request(path, method: :get, body: nil)
    @requests << [method, path]
    return { "data" => { "attributes" => @detail } } if method == :get && path.end_with?("/buildBetaDetail")
    if method == :post && path == "/v1/betaGroups/home/relationships/builds"
      @membership << body.fetch(:data).first.fetch(:id)
      return {}
    end
    return {} if method == :patch && path == "/v1/builds/target"
    raise "Unexpected fixture request"
  end
end

class APITests < Minitest::Test
  def setup
    @api = FixtureASC.new
    @catalog = TestFlight::Catalog.new(@api)
  end
  def preflight(number = "", version = "1.4.0")
    @catalog.preflight(marketing_version: version, requested_number: number)
  end
  def test_get_only_inventory_selects_next_number_including_processing
    @api.inventory << @api.build("processing", "1.4.0", "30", "PROCESSING")
    receipt = preflight
    assert_equal "31", receipt[:build_number]
    assert_equal ["Garofalo Home"], receipt[:tester_groups]
    assert_equal false, receipt[:reservation]
    assert @api.requests.all? { |request| request.first == :get }
  end
  def test_identity_collision_and_same_number_different_version
    assert_raises(RuntimeError) { preflight("27") }
    assert_equal "27", preflight("27", "1.5.0")[:build_number]
    @api.inventory << @api.build("duplicate", "1.4.0", "27")
    assert_raises(RuntimeError) { @catalog.find_build(marketing_version: "1.4.0", number: "27") }
  end
  def test_audience_and_ambiguous_source_fail_closed_without_mutation
    @api.groups.first["attributes"]["name"] = "Unapproved"
    assert_raises(RuntimeError) { preflight }
    assert @api.requests.all? { |request| request.first == :get }
    @api.groups.first["attributes"]["name"] = "Garofalo Home"
    @api.inventory << @api.build("other-source", "1.1.0", "6")
    assert_raises(RuntimeError) { preflight }
    assert_equal "source", @catalog.source_build("6", "1.0.0")["id"]
  end
  def test_source_must_be_processed_and_available
    @api.inventory.first["attributes"]["processingState"] = "PROCESSING"
    assert_raises(RuntimeError) { preflight }
    @api.inventory.first["attributes"]["processingState"] = "VALID"
    @api.detail["internalBuildState"] = "EXPIRED"
    assert_raises(RuntimeError) { preflight }
  end
  def test_invalid_numbers_and_source_project_versions
    ["0", "-1", "1.2", "1\n", "$(id)"].each { |number| assert_raises(RuntimeError) { preflight(number) } }
    assert_raises(RuntimeError) { preflight("28", "1.4.0\ninjected=true") }
    require "tempfile"
    Tempfile.create("project") do |file|
      file.write("MARKETING_VERSION = 1.4.0;\n" * 4); file.flush
      assert_raises(RuntimeError) { run_preflight(@api, { "MARKETING_VERSION" => "1.5.0", "RELEASE_MODE" => "upload" }, project: file.path) }
    end
  end
  def test_distribution_verifies_exact_identity_and_approved_membership
    result = distribute_testflight(@api, { "BUILD_NUMBER" => "27", "MARKETING_VERSION" => "1.4.0" }, sleep_for: ->(_) { flunk "Should already be available" })
    assert_equal "27", result[:build_number]
    assert @api.requests.all? { |request| request.first == :get }
  end
  def test_distribution_does_not_claim_assignment_is_availability
    @api.membership.delete("target")
    assert_raises(RuntimeError) { distribute_testflight(@api, { "BUILD_NUMBER" => "27", "MARKETING_VERSION" => "1.4.0" }, sleep_for: ->(_) {}) }
    assert @api.requests.all? { |request| request.first == :get }, "Automatic group must not be reassigned"
  end
  def test_failed_processing_never_distributes
    @api.inventory.last["attributes"]["processingState"] = "INVALID"
    assert_raises(RuntimeError) { distribute_testflight(@api, { "BUILD_NUMBER" => "27", "MARKETING_VERSION" => "1.4.0" }, sleep_for: ->(_) {}) }
    assert @api.requests.all? { |request| request.first == :get }
  end
  def test_existing_nonautomatic_group_assignment
    @api.groups.first["attributes"]["hasAccessToAllBuilds"] = false
    @api.membership.delete("target")
    distribute_testflight(@api, { "BUILD_NUMBER" => "27", "MARKETING_VERSION" => "1.4.0" }, sleep_for: ->(_) {})
    assert_equal [[:post, "/v1/betaGroups/home/relationships/builds"]], @api.requests.reject { |request| request.first == :get }
  end
  def test_origin_guard_and_read_only_mutation_rejection
    %w[https://example.com/page http://api.appstoreconnect.apple.com/v1/apps https://secret@api.appstoreconnect.apple.com/v1/apps].each { |path| assert_raises(RuntimeError) { AppStoreConnect.api_uri(path) } }
    assert_equal "api.appstoreconnect.apple.com", AppStoreConnect.api_uri("/v1/apps").host
    client = AppStoreConnect.allocate
    client.instance_variable_set(:@read_only, true)
    assert_raises(RuntimeError) { client.request("/v1/apps", method: :post) }
  end
  def test_pagination_and_repeat_guard
    client = AppStoreConnect.allocate
    pages = { "/one" => { "data" => [1], "links" => { "next" => "/two" } }, "/two" => { "data" => [2], "links" => {} } }
    client.define_singleton_method(:request) { |path| pages.fetch(path) }
    assert_equal [1, 2], client.list("/one")
    pages["/two"]["links"]["next"] = "/one"
    assert_raises(RuntimeError) { client.list("/one") }
  end
  def test_http_error_retains_status_and_apple_code_without_private_response_fields
    response = Net::HTTPUnprocessableEntity.new("1.1", "422", "Unprocessable Entity")
    response.define_singleton_method(:body) do
      JSON.generate(errors: [{ code: "STATE_ERROR.BETA_REVIEW", title: "Private contact", detail: "private@example.invalid", meta: { token: "private-jwt" } }])
    end
    http = Object.new
    http.define_singleton_method(:request) { |_| response }
    client = AppStoreConnect.allocate
    client.define_singleton_method(:token) { "fixture-token" }
    Net::HTTP.stub(:start, ->(*_args, **_options, &block) { block.call(http) }) do
      error = assert_raises(AppStoreConnect::RequestError) { client.request("/v1/betaAppReviewSubmissions?private=value", method: :post, body: { private: "fixture-body" }) }
      assert_equal "422", error.status
      assert_equal ["STATE_ERROR.BETA_REVIEW"], error.apple_codes
      assert_includes error.message, "POST /v1/betaAppReviewSubmissions failed (422)"
      %w[private@example.invalid Private private-jwt fixture-token fixture-body private=value permissions agreements].each { |value| refute_includes error.message, value }
    end
  end
  def test_error_code_parser_rejects_malformed_or_unbounded_response_content
    ["not-json", "null", "[]", '{"errors":{}}', '{"errors":[null,1,"text",{}]}', "x" * 262_145].each do |body|
      assert_empty AppStoreConnect.error_codes(body)
    end
    assert_equal ["STATE_ERROR", "ENTITY_ERROR.ATTRIBUTE.INVALID"], AppStoreConnect.error_codes(JSON.generate(errors: [{ code: "STATE_ERROR" }, { code: "STATE_ERROR" }, { code: "ENTITY_ERROR.ATTRIBUTE.INVALID" }, { code: "secret@example.invalid" }, { code: "::warning::injected" }]))
  end
  def test_error_code_parser_never_prints_configured_credential_values
    name = "APP_STORE_CONNECT_API_KEY_ID"
    previous = ENV[name]
    ENV[name] = "FIXTUREKEYID"
    assert_empty AppStoreConnect.error_codes(JSON.generate(errors: [{ code: "FIXTUREKEYID" }, { code: "STATE_ERROR.FIXTUREKEYID" }]))
  ensure
    ENV[name] = previous
  end
end
