#!/usr/bin/env ruby
require "yaml"
require "open3"
root = File.expand_path("../..", __dir__)
workflow = YAML.safe_load(File.read("#{root}/.github/workflows/testflight.yml"), aliases: true)
def check(condition, label)
  raise "Workflow contract failed: #{label}" unless condition
end
check((workflow["on"] || workflow.fetch(true)).keys == ["workflow_dispatch"], "manual-only trigger")
check(workflow["permissions"] == { "contents" => "read" }, "default read-only permissions")
check(workflow["concurrency"] == { "group" => "shopping-testflight", "cancel-in-progress" => false }, "serialized release, no cancellation")
check(File.executable?("#{root}/.github/scripts/validate-release-source.sh"), "source-validation entrypoint is executable for direct workflow invocation")
jobs = workflow.fetch("jobs")
%w[upload verify preflight].each do |name|
  job = jobs.fetch(name)
  check(job["environment"] == "testflight" && job["needs"] == "intent", "protected intent prerequisite #{name}")
  check(job.fetch("if").include?("github.ref == 'refs/heads/main'"), "main guard #{name}")
  check(job.fetch("if").include?("!inputs."), "exclusive mode guard #{name}")
  check(job.fetch("steps").first == { "uses" => "actions/checkout@v5" }, "exact dispatched checkout #{name}")
end
intent = jobs.fetch("intent").fetch("steps").first.fetch("run")
[false, true].repeated_permutation(3).each do |modes|
  ["refs/heads/main", "refs/heads/feature"].each do |ref|
    env = { "REF" => ref, "UPLOAD" => modes[0].to_s, "VERIFY" => modes[1].to_s, "PREFLIGHT" => modes[2].to_s, "BUILD" => "28" }
    _out, _err, status = Open3.capture3(env, "bash", "-c", intent)
    check(status.success? == (ref == "refs/heads/main" && modes.count(true) == 1), "executed mode/ref truth table")
  end
end
_out, _err, status = Open3.capture3({ "REF" => "refs/heads/main", "UPLOAD" => "false", "VERIFY" => "true", "PREFLIGHT" => "false", "BUILD" => "" }, "bash", "-c", intent)
check(!status.success?, "verify needs explicit build")
check(jobs["upload"]["permissions"] == { "contents" => "read", "actions" => "read" }, "upload can read required CI only")
upload = jobs["upload"]["steps"].find { |step| step["name"] == "Archive, validate, and upload" }
check(upload.fetch("env").fetch("BUILD_NUMBER") == "${{ steps.preflight.outputs.build_number }}", "selected number used for upload")
check(upload.fetch("env").fetch("MARKETING_VERSION") == "${{ steps.preflight.outputs.marketing_version }}", "selected version used for upload")
secrets = %w[APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 APP_STORE_PROVISIONING_PROFILE_BASE64 APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64 APPLE_DISTRIBUTION_CERTIFICATE_BASE64 APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD]
secrets.each { |name| check(upload.fetch("env")[name] == "${{ secrets.#{name} }}", "protected secret #{name}") }
preflight = jobs["preflight"]["steps"].last
check(preflight["run"] == "ruby .github/scripts/preflight-testflight.rb", "preflight entrypoint")
check(preflight["env"].keys.grep(/CERTIFICATE|PROVISIONING/).empty?, "preflight receives no signing assets")
check(jobs["upload"]["steps"].any? { |step| step["run"] == "sudo xcode-select -s /Applications/Xcode_26.3.app" }, "release SDK pin")
script = File.read("#{root}/.github/scripts/upload-testflight.sh")
check(!script.include?("PROVISIONING_PROFILE_SPECIFIER="), "no global profile override")
check(script.include?('SHOPPING_IPHONE_PROFILE_UUID="$IPHONE_PROFILE_UUID"') && script.include?('SHOPPING_WATCH_PROFILE_UUID="$WATCH_PROFILE_UUID"'), "per-target overrides")
check(script.index("require-release-ci.py") < script.index("security import"), "CI before signing")
check(script.index('RELEASE_MODE=upload ruby') < script.index('xcrun altool --upload-app'), "collision recheck before upload")
%w[validate-cloudkit-sharing.py validate-release-identity.py].each { |name| check(script.index(name) < script.index('xcrun altool --upload-app'), "#{name} before upload") }
project = File.read("#{root}/Shopping.xcodeproj/project.pbxproj")
check(project.scan('PROVISIONING_PROFILE_SPECIFIER = "$(SHOPPING_IPHONE_PROFILE_UUID)"').length == 1, "iPhone release binding")
check(project.scan('PROVISIONING_PROFILE_SPECIFIER = "$(SHOPPING_WATCH_PROFILE_UUID)"').length == 1, "Watch release binding")
# These must fail before touching keychains or contacting Apple.
upload_path = "#{root}/.github/scripts/upload-testflight.sh"
output, status = Open3.capture2e("env", "-i", "PATH=#{ENV.fetch('PATH')}", "bash", upload_path)
check(!status.success? && output.include?("APP_STORE_CONNECT_API_ISSUER_ID is not configured"), "missing configuration rejection")
values = secrets.map { |key| "#{key}=fixture" } + ["BUILD_NUMBER=0", "MARKETING_VERSION=1.4.0"]
output, status = Open3.capture2e("env", "-i", "PATH=#{ENV.fetch('PATH')}", *values, "bash", upload_path)
check(!status.success? && output.include?("BUILD_NUMBER must be a positive integer"), "invalid build rejection")
puts "Workflow intent, protection, signing and upload gate contracts passed."
