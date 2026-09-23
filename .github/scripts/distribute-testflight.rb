#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

$stdout.sync = true

class AppStoreConnect
  def initialize
    key_data = Base64.decode64(ENV.fetch("APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64"))
    @key = OpenSSL::PKey.read(key_data)
    @key_id = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
    @issuer_id = ENV.fetch("APP_STORE_CONNECT_API_ISSUER_ID")
  end

  def request(path, method: :get, body: nil)
    uri = URI.join("https://api.appstoreconnect.apple.com", path)
    request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    unless response.is_a?(Net::HTTPSuccess)
      raise "App Store Connect #{method.upcase} #{uri.path} failed (#{response.code}): #{response.body}"
    end
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end

  def list(path)
    results = []
    while path
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

def path_with_query(path, query)
  "#{path}?#{URI.encode_www_form(query)}"
end

def find_build(client, app_id, number)
  query = { "filter[app]" => app_id, "filter[version]" => number, "limit" => 10 }
  client.list(path_with_query("/v1/builds", query)).find { |build| build.dig("attributes", "version") == number }
end

def group_build_ids(client, group_id)
  client.list("/v1/betaGroups/#{group_id}/relationships/builds?limit=200").map { |build| build.fetch("id") }
end

client = AppStoreConnect.new
bundle_id = ENV.fetch("BUNDLE_IDENTIFIER", "com.mggarofalo.shopping")
target_number = ENV.fetch("BUILD_NUMBER")
source_number = ENV.fetch("DISTRIBUTE_FROM_BUILD")
apps = client.list(path_with_query("/v1/apps", "filter[bundleId]" => bundle_id, "limit" => 10))
app = apps.find { |entry| entry.dig("attributes", "bundleId") == bundle_id }
raise "App #{bundle_id} was not found in App Store Connect" unless app
app_id = app.fetch("id")
source = find_build(client, app_id, source_number)
raise "Source build #{source_number} was not found" unless source
puts "Source build #{source_number}: #{source.dig('attributes', 'processingState')}"

groups = client.list("/v1/apps/#{app_id}/betaGroups?limit=200")
source_groups = groups.select do |group|
  group_build_ids(client, group.fetch("id")).include?(source.fetch("id"))
end
raise "Source build #{source_number} has no tester groups to copy" if source_groups.empty?
puts "Source tester groups: #{source_groups.map { |group| group.dig('attributes', 'name') }.join(', ')}"
source_groups.each do |group|
  puts "#{group.dig('attributes', 'name')} automatically receives all builds" if group.dig("attributes", "hasAccessToAllBuilds")
end

target = nil
24.times do
  target = find_build(client, app_id, target_number)
  state = target&.dig("attributes", "processingState")
  puts "Build #{target_number}: #{state || 'not yet visible'}"
  break if state == "VALID"
  raise "Build #{target_number} failed processing: #{state}" if %w[FAILED INVALID].include?(state)
  sleep 30
end
raise "Build #{target_number} was not processed within 12 minutes" unless target&.dig("attributes", "processingState") == "VALID"
initial_detail = client.request("/v1/builds/#{target.fetch('id')}/buildBetaDetail").fetch("data")
initial_internal_state = initial_detail.dig("attributes", "internalBuildState")
puts "Build #{target_number} initial internal state: #{initial_internal_state}"
if %w[MISSING_EXPORT_COMPLIANCE PROCESSING_EXCEPTION EXPIRED].include?(initial_internal_state)
  raise "Build #{target_number} cannot reach internal testers: #{initial_internal_state}"
end

source_groups.each do |group|
  group_id = group.fetch("id")
  next if group_build_ids(client, group_id).include?(target.fetch("id"))
  next if group.dig("attributes", "hasAccessToAllBuilds")
  body = { data: [{ type: "builds", id: target.fetch("id") }] }
  client.request("/v1/betaGroups/#{group_id}/relationships/builds", method: :post, body: body)
  puts "Added build #{target_number} to #{group.dig('attributes', 'name')}"
end

24.times do |attempt|
  missing = source_groups.reject do |group|
    group_build_ids(client, group.fetch("id")).include?(target.fetch("id"))
  end
  break if missing.empty?
  raise "Build #{target_number} is absent from #{missing.map { |group| group.dig('attributes', 'name') }.join(', ')} after 12 minutes" if attempt == 23
  puts "Waiting for build #{target_number} in #{missing.map { |group| group.dig('attributes', 'name') }.join(', ')}"
  sleep 30
end
beta_detail = client.request("/v1/builds/#{target.fetch('id')}/buildBetaDetail").fetch("data")
internal_state = beta_detail.dig("attributes", "internalBuildState")
external_state = beta_detail.dig("attributes", "externalBuildState")
puts "Build #{target_number} internal state: #{internal_state}"
puts "Build #{target_number} external state: #{external_state}"
ready_states = %w[READY_FOR_BETA_TESTING IN_BETA_TESTING]
if source_groups.any? { |group| group.dig("attributes", "isInternalGroup") } && !ready_states.include?(internal_state)
  raise "Build #{target_number} is assigned but not available to internal testers: #{internal_state}"
end
if source_groups.any? { |group| !group.dig("attributes", "isInternalGroup") } && !ready_states.include?(external_state)
  raise "Build #{target_number} is assigned but not available to external testers: #{external_state}"
end
puts "Build #{target_number} is processed and assigned to the source build's tester groups."
