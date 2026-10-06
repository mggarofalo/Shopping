require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

# Only the protected release jobs construct this client. Preflight additionally
# refuses every mutation, even if a caller accidentally asks for one.
class AppStoreConnect
  class RequestError < StandardError
    attr_reader :status, :apple_codes

    def initialize(method, path, response)
      @status = response.code
      @apple_codes = AppStoreConnect.error_codes(response.body)
      suffix = apple_codes.empty? ? "" : "; Apple error codes: #{apple_codes.join(', ')}"
      super("App Store Connect #{method.upcase} #{path} failed (#{status})#{suffix}")
    end
  end

  # Retain machine-readable diagnostics only. Apple's free-text detail, title,
  # metadata and response headers may contain private values and stay unlogged.
  def self.error_codes(body)
    return [] unless body.is_a?(String) && body.bytesize <= 262_144
    payload = JSON.parse(body)
    return [] unless payload.is_a?(Hash) && payload["errors"].is_a?(Array)
    protected_values = ENV.values_at("APP_STORE_CONNECT_API_KEY_ID", "APP_STORE_CONNECT_API_ISSUER_ID", "APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64").compact.reject(&:empty?)
    payload["errors"].first(5).map do |error|
      code = error.is_a?(Hash) && error["code"]
      next unless code.is_a?(String) && /\A[A-Z][A-Z0-9_.-]{0,119}\z/.match?(code)
      next if protected_values.any? { |value| code.include?(value) }
      code
    end.compact.uniq
  rescue JSON::ParserError
    []
  end

  def initialize(read_only: false)
    @read_only = read_only
    @key = OpenSSL::PKey.read(Base64.strict_decode64(ENV.fetch("APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64").gsub(/\s/, "")))
    @key_id = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
    @issuer_id = ENV.fetch("APP_STORE_CONNECT_API_ISSUER_ID")
  end

  def self.api_uri(path)
    uri = URI.join("https://api.appstoreconnect.apple.com", path)
    unless uri.scheme == "https" && uri.host == "api.appstoreconnect.apple.com" && uri.port == 443 && !uri.userinfo
      raise "Refusing an App Store Connect request outside the Apple API origin"
    end
    uri
  end

  def request(path, method: :get, body: nil)
    raise "Read-only preflight cannot mutate App Store Connect" if @read_only && method != :get
    uri = self.class.api_uri(path)
    type = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    request = type.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise RequestError.new(method, uri.path, response)
    end
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end

  def list(path)
    results, visited = [], []
    while path
      raise "App Store Connect pagination repeated a page" if visited.include?(path)
      visited << path
      response = request(path)
      results.concat(response.fetch("data"))
      path = response.dig("links", "next")
    end
    results
  end

  private

  def token
    header = { alg: "ES256", kid: @key_id, typ: "JWT" }
    now = Time.now.to_i
    claims = { iss: @issuer_id, iat: now, exp: now + 600, aud: "appstoreconnect-v1" }
    message = [header, claims].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
    signature = @key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(message))
    pair = OpenSSL::ASN1.decode(signature).value
    raw_signature = pair.map { |integer| integer.value.to_s(2).rjust(32, "\0") }.join
    "#{message}.#{Base64.urlsafe_encode64(raw_signature, padding: false)}"
  end
end

module TestFlight
  BUNDLE_ID = "com.mggarofalo.shopping".freeze
  EXPECTED_GROUPS = ["Garofalo Home"].freeze
  READY_STATES = %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].freeze

  def self.query(path, values)
    "#{path}?#{URI.encode_www_form(values)}"
  end

  def self.number(value)
    raise "Build number must be a positive integer" unless /\A[1-9][0-9]*\z/.match?(value.to_s)
    value.to_s
  end

  def self.version(value)
    raise "Marketing version must have three numeric components" unless /\A[0-9]+\.[0-9]+\.[0-9]+\z/.match?(value.to_s)
    value
  end

  def self.project_version(project = File.expand_path("../../Shopping.xcodeproj/project.pbxproj", __dir__))
    versions = File.read(project).scan(/MARKETING_VERSION\s*=\s*([^;]+);/).flatten.map(&:strip)
    unless versions.length == 4 && versions.uniq.length == 1
      raise "All four iPhone/Watch marketing versions must match"
    end
    version(versions.first)
  end

  class Catalog
    attr_reader :client, :app_id

    def initialize(client)
      @client = client
      apps = client.list(TestFlight.query("/v1/apps", "filter[bundleId]" => BUNDLE_ID, "limit" => 10))
      matches = apps.select { |app| app.dig("attributes", "bundleId") == BUNDLE_ID }
      raise "Expected exactly one Shopping App Store Connect app" unless matches.length == 1
      @app_id = matches.first.fetch("id")
    end

    def builds(marketing_version: nil, number: nil)
      values = { "filter[app]" => app_id, "filter[preReleaseVersion.platform]" => "IOS", "include" => "preReleaseVersion", "limit" => 200, "sort" => "-uploadedDate" }
      values["filter[preReleaseVersion.version]"] = TestFlight.version(marketing_version) if marketing_version
      values["filter[version]"] = TestFlight.number(number) if number
      client.list(TestFlight.query("/v1/builds", values))
    end

    def find_build(marketing_version:, number:)
      matches = builds(marketing_version: marketing_version, number: number).select { |build| build.dig("attributes", "version") == number }
      raise "Ambiguous App Store Connect version/build identity" if matches.length > 1
      matches.first
    end

    def source_build(number, marketing_version = nil)
      matches = builds(marketing_version: marketing_version, number: number).select { |build| build.dig("attributes", "version") == number }
      raise "Source build is missing or ambiguous; specify DISTRIBUTE_FROM_VERSION" unless matches.length == 1
      source = matches.first
      raise "Source tester build is not processed" unless source.dig("attributes", "processingState") == "VALID"
      source
    end

    def group_build_ids(id)
      client.list("/v1/betaGroups/#{id}/relationships/builds?limit=200").map { |build| build.fetch("id") }
    end

    def pending_beta_reviews(marketing_version:, except_build_id: nil)
      builds(marketing_version: marketing_version).reject { |build| build.fetch("id") == except_build_id }.flat_map do |build|
        reviews = client.list(TestFlight.query("/v1/betaAppReviewSubmissions", "filter[build]" => build.fetch("id"), "limit" => 200))
        reviews.map do |review|
          state = review.dig("attributes", "betaReviewState")
          next unless %w[WAITING_FOR_REVIEW IN_REVIEW].include?(state)
          { build_number: TestFlight.number(build.dig("attributes", "version")), build_id: build.fetch("id"), review_id: review.fetch("id"), state: state }
        end.compact
      end
    end

    def require_beta_review_slot!(marketing_version:, build_number: nil, except_build_id: nil)
      blockers = pending_beta_reviews(marketing_version: marketing_version, except_build_id: except_build_id)
      return if blockers.empty?
      waiting = blockers.map { |review| "#{marketing_version} (#{review.fetch(:build_number)}): #{review.fetch(:state)}" }.join(", ")
      recovery = if except_build_id
        "retry verify-only for #{marketing_version} (#{build_number}) after its review completes. This build has not been submitted or assigned externally."
      else
        "retry preflight after its review completes, before uploading a new build. No upload or external assignment has been performed by this preflight."
      end
      raise "External beta review blocked by existing review #{waiting}. Apple allows one build per version in review. Preserve that submission; #{recovery}"
    end

    def source_groups(source)
      groups = client.list("/v1/apps/#{app_id}/betaGroups?limit=200")
      groups = groups.select { |group| group_build_ids(group.fetch("id")).include?(source.fetch("id")) }
      unless groups.map { |group| group.dig("attributes", "name") }.sort == EXPECTED_GROUPS.sort
        raise "Source tester groups differ from the approved Garofalo Home audience"
      end
      detail = client.request("/v1/builds/#{source.fetch('id')}/buildBetaDetail").fetch("data").fetch("attributes")
      groups.each do |group|
        state = detail.fetch(group.dig("attributes", "isInternalGroup") ? "internalBuildState" : "externalBuildState")
        raise "Source build is not available to its tester groups" unless READY_STATES.include?(state)
      end
      groups
    end

    def preflight(marketing_version:, requested_number: "", source_number: "6", source_version: nil)
      TestFlight.version(marketing_version)
      inventory = builds
      numeric = inventory.map { |build| TestFlight.number(build.dig("attributes", "version")).to_i }
      selected = requested_number.to_s.empty? ? ((numeric.max || 0) + 1).to_s : TestFlight.number(requested_number)
      if find_build(marketing_version: marketing_version, number: selected)
        raise "#{marketing_version} (#{selected}) already exists; use verify-only instead of another upload"
      end
      source = source_build(TestFlight.number(source_number), source_version)
      groups = source_groups(source)
      versions = client.list(TestFlight.query("/v1/preReleaseVersions", "filter[app]" => app_id, "filter[platform]" => "IOS", "limit" => 200))
      names = versions.each_with_object({}) { |entry, map| map[entry.fetch("id")] = entry.dig("attributes", "version") }
      { marketing_version: marketing_version, build_number: selected, source_build: source_number,
        tester_groups: groups.map { |group| group.dig("attributes", "name") },
        recent_builds: inventory.first(20).map { |build| { marketing_version: names[build.dig("relationships", "preReleaseVersion", "data", "id")], build_number: build.dig("attributes", "version"), processing_state: build.dig("attributes", "processingState"), uploaded_at: build.dig("attributes", "uploadedDate") } },
        read_only: true, reservation: false }
    end
  end
end
