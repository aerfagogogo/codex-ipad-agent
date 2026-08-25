#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "open3"
require "tmpdir"
require "uri"

def abort_release(message)
  warn "TestFlight 内测分发失败：#{message}"
  exit 1
end

def required_env(name)
  value = ENV[name].to_s
  abort_release("缺少环境变量 #{name}") if value.empty?
  value
end

def base64url(value)
  Base64.urlsafe_encode64(value).delete("=")
end

def app_store_connect_token
  now = Time.now.to_i
  header = { alg: "ES256", kid: required_env("APP_STORE_CONNECT_API_KEY_ID"), typ: "JWT" }
  payload = {
    iss: required_env("APP_STORE_CONNECT_API_ISSUER_ID"),
    iat: now,
    exp: now + 1_200,
    aud: "appstoreconnect-v1"
  }
  signing_input = [base64url(header.to_json), base64url(payload.to_json)].join(".")
  key = OpenSSL::PKey.read(File.read(required_env("APP_STORE_CONNECT_API_KEY_PATH")))
  der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))

  # 核心逻辑：OpenSSL 返回 DER 编码签名，而 JWT ES256 要求固定 64 字节的 r+s。
  raw = OpenSSL::ASN1.decode(der).value.map do |integer|
    bytes = integer.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\0")
  end.join
  "#{signing_input}.#{base64url(raw)}"
end

class AscClient
  def initialize(&token_provider)
    @token_provider = token_provider
  end

  def get(path, query = {})
    request("GET", path, query: query)
  end

  def post(path, body)
    request("POST", path, body: body)
  end

  def patch(path, body, allowed_statuses: [])
    request("PATCH", path, body: body, allowed_statuses: allowed_statuses)
  end

  private

  def request(method, path, query: {}, body: nil, allowed_statuses: [])
    uri = URI::HTTPS.build(
      host: "api.appstoreconnect.apple.com",
      path: path,
      query: query.empty? ? nil : URI.encode_www_form(query)
    )
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    # Apple 处理构建偶尔会超过 JWT 的 20 分钟有效期。每次请求重新签发短期
    # token，避免长轮询在构建即将可用时因为 401 中断。
    request["Authorization"] = "Bearer #{@token_provider.call}"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    status = response.code.to_i
    return {} if response.body.to_s.empty? && (status.between?(200, 299) || allowed_statuses.include?(status))

    parsed = JSON.parse(response.body)
    return parsed if status.between?(200, 299) || allowed_statuses.include?(status)

    abort_release("#{method} #{path} 返回 HTTP #{status}：#{JSON.pretty_generate(parsed)}")
  end
end

def command_output(*args)
  output, error, status = Open3.capture3(*args)
  abort_release("#{args.join(' ')} 执行失败：#{error}") unless status.success?
  output.strip
end

def ipa_metadata(ipa)
  abort_release("找不到 IPA：#{ipa}") unless File.file?(ipa)
  Dir.mktmpdir("mimi-ipa-") do |dir|
    command_output("unzip", "-q", ipa, "-d", dir)
    app = Dir.glob(File.join(dir, "Payload", "*.app")).first
    abort_release("IPA 中不存在 Payload/*.app") unless app
    plist = File.join(app, "Info.plist")
    return {
      bundle_id: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist),
      version: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", plist),
      build: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", plist)
    }
  end
end

def tester_name_parts(email)
  words = email.split("@", 2).first.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map(&:capitalize)
  first_name = words.shift || "Beta"
  last_name = words.empty? ? "Tester" : words.join(" ")
  [first_name, last_name]
end

def ensure_external_tester(client, app_id, group_id, email)
  tester = client.get("/v1/betaTesters", {
    "filter[email]" => email,
    "filter[apps]" => app_id,
    "limit" => "20"
  }).fetch("data").first

  unless tester
    first_name, last_name = tester_name_parts(email)
    tester = client.post("/v1/betaTesters", {
      data: {
        type: "betaTesters",
        attributes: { firstName: first_name, lastName: last_name, email: email },
        relationships: {
          betaGroups: { data: [{ type: "betaGroups", id: group_id }] }
        }
      }
    }).fetch("data")
    return tester
  end

  groups = client.get("/v1/betaTesters/#{tester.fetch('id')}/betaGroups", { "limit" => "200" }).fetch("data")
  unless groups.any? { |group| group.fetch("id") == group_id }
    client.post("/v1/betaTesters/#{tester.fetch('id')}/relationships/betaGroups", {
      data: [{ type: "betaGroups", id: group_id }]
    })
  end
  tester
end

expected_bundle_id = required_env("IOS_BUNDLE_ID")
group_id = required_env("TESTFLIGHT_BETA_GROUP_ID")
whats_new = required_env("TESTFLIGHT_WHATS_NEW")
external_group_id = ENV.fetch("TESTFLIGHT_EXTERNAL_BETA_GROUP_ID", "").strip
primary_tester_emails = ENV.fetch("TESTFLIGHT_PRIMARY_TESTER_EMAILS", "")
                           .split(/[\s,;]+/).map(&:strip).reject(&:empty?).uniq
ipa = ARGV.fetch(0) { abort_release("用法：distribute_internal_build.rb APP.ipa|--resume") }
metadata = if ipa == "--resume"
             # 上传成功后本地临时目录可能已被清理。恢复分发只需要精确定位 ASC
             # 中的构建，不应为了读取 Info.plist 再次归档或重复上传。
             {
               bundle_id: expected_bundle_id,
               version: required_env("TESTFLIGHT_RELEASE_VERSION"),
               build: required_env("TESTFLIGHT_BUILD_NUMBER")
             }
           else
             ipa_metadata(ipa)
           end
abort_release("Bundle ID 不匹配：#{metadata[:bundle_id]}") unless metadata[:bundle_id] == expected_bundle_id

client = AscClient.new { app_store_connect_token }
app = client.get("/v1/apps", { "filter[bundleId]" => expected_bundle_id, "limit" => "1" }).fetch("data").first
abort_release("App Store Connect 中找不到 #{expected_bundle_id}") unless app

# 等待 Apple 完成处理；上传和处理速度不可控，但不会重复归档或重复上传。
deadline = Time.now + 1_800
build = nil
loop do
  result = client.get("/v1/builds", {
    "filter[app]" => app.fetch("id"),
    "filter[preReleaseVersion.version]" => metadata[:version],
    "filter[version]" => metadata[:build],
    "limit" => "1"
  })
  build = result.fetch("data").first
  state = build&.dig("attributes", "processingState")
  puts "等待 Apple 处理：#{metadata[:version]} (#{metadata[:build]}) state=#{state || 'NOT_FOUND'}"
  break if state == "VALID"
  abort_release("Apple 处理失败：#{state}") if %w[FAILED INVALID].include?(state)
  abort_release("等待构建 VALID 超时") if Time.now >= deadline
  sleep 30
end

build_id = build.fetch("id")
client.patch("/v1/builds/#{build_id}", {
  data: { type: "builds", id: build_id, attributes: { usesNonExemptEncryption: false } }
}, allowed_statuses: [409])

localizations = client.get("/v1/builds/#{build_id}/betaBuildLocalizations", { "limit" => "20" }).fetch("data")
localization = localizations.find { |item| item.dig("attributes", "locale") == "zh-Hans" } || localizations.first
if localization
  client.patch("/v1/betaBuildLocalizations/#{localization.fetch('id')}", {
    data: {
      type: "betaBuildLocalizations",
      id: localization.fetch("id"),
      attributes: { whatsNew: whats_new }
    }
  })
else
  client.post("/v1/betaBuildLocalizations", {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "zh-Hans", whatsNew: whats_new },
      relationships: { build: { data: { type: "builds", id: build_id } } }
    }
  })
end

group = client.get("/v1/betaGroups/#{group_id}").fetch("data")
abort_release("目标组不是内部测试组") unless group.dig("attributes", "isInternalGroup") == true
group_builds = client.get("/v1/betaGroups/#{group_id}/builds", { "limit" => "200" }).fetch("data")
unless group_builds.any? { |item| item.fetch("id") == build_id }
  client.post("/v1/betaGroups/#{group_id}/relationships/builds", {
    data: [{ type: "builds", id: build_id }]
  })
end

verified = client.get("/v1/betaGroups/#{group_id}/builds", { "limit" => "200" }).fetch("data")
abort_release("构建未成功关联内测组") unless verified.any? { |item| item.fetch("id") == build_id }

# 发布成功不能只看组关联。继续回读测试员和 What to Test，避免产生“组里没有人”
# 或测试说明写入失败但脚本仍报成功的半完成状态。
testers = client.get("/v1/betaGroups/#{group_id}/betaTesters", { "limit" => "200" })
tester_count = testers.dig("meta", "paging", "total") || testers.fetch("data").length
abort_release("目标内测组没有测试员") if tester_count.zero?

# 内测组有关联测试员不等于邀请已经发出。首次发布时主动邀请仍处于
# NOT_INVITED 的测试员，避免构建在 ASC 后台可见、手机端却收不到。
invited_count = 0
if ENV.fetch("TESTFLIGHT_INVITE_PENDING_TESTERS", "1") == "1"
  testers.fetch("data").select { |tester| tester.dig("attributes", "state") == "NOT_INVITED" }.each do |tester|
    client.post("/v1/betaTesterInvitations", {
      data: {
        type: "betaTesterInvitations",
        relationships: {
          app: { data: { type: "apps", id: app.fetch("id") } },
          betaTester: { data: { type: "betaTesters", id: tester.fetch("id") } }
        }
      }
    })
    invited_count += 1
  end
end

external_state = "disabled"
external_invited_count = 0
unless external_group_id.empty?
  abort_release("已配置外测组但没有 TESTFLIGHT_PRIMARY_TESTER_EMAILS") if primary_tester_emails.empty?

  external_group = client.get("/v1/betaGroups/#{external_group_id}").fetch("data")
  abort_release("目标外测组却被配置成内部组") if external_group.dig("attributes", "isInternalGroup") == true

  primary_tester_emails.each do |email|
    ensure_external_tester(client, app.fetch("id"), external_group_id, email)
  end

  external_builds = client.get("/v1/betaGroups/#{external_group_id}/builds", { "limit" => "200" }).fetch("data")
  unless external_builds.any? { |item| item.fetch("id") == build_id }
    client.post("/v1/betaGroups/#{external_group_id}/relationships/builds", {
      data: [{ type: "builds", id: build_id }]
    })
  end

  if ENV.fetch("TESTFLIGHT_EXTERNAL_AUTO_NOTIFY", "1") == "1"
    client.patch("/v1/buildBetaDetails/#{build_id}", {
      data: { type: "buildBetaDetails", id: build_id, attributes: { autoNotifyEnabled: true } }
    }, allowed_statuses: [409])
  end

  beta_detail = client.get("/v1/builds/#{build_id}/buildBetaDetail").fetch("data")
  external_state = beta_detail.dig("attributes", "externalBuildState").to_s
  if external_state == "READY_FOR_BETA_SUBMISSION" && ENV.fetch("TESTFLIGHT_EXTERNAL_AUTO_SUBMIT", "1") == "1"
    submission = client.post("/v1/betaAppReviewSubmissions", {
      data: {
        type: "betaAppReviewSubmissions",
        relationships: { build: { data: { type: "builds", id: build_id } } }
      }
    }).fetch("data")
    external_state = submission.dig("attributes", "betaReviewState").to_s
  end

  external_testers = client.get("/v1/betaGroups/#{external_group_id}/betaTesters", { "limit" => "200" })
  external_tester_data = external_testers.fetch("data")
  external_emails = external_tester_data.map { |tester| tester.dig("attributes", "email").to_s.downcase }
  missing_emails = primary_tester_emails.reject { |email| external_emails.include?(email.downcase) }
  abort_release("外测组缺少主测试员：#{missing_emails.join(', ')}") unless missing_emails.empty?

  min_external_testers = ENV.fetch("TESTFLIGHT_MIN_EXTERNAL_TESTERS", primary_tester_emails.length.to_s).to_i
  abort_release("外测组测试员少于 #{min_external_testers} 人") if external_tester_data.length < min_external_testers

  if external_state == "IN_BETA_TESTING"
    external_tester_data.select do |tester|
      primary_tester_emails.map(&:downcase).include?(tester.dig("attributes", "email").to_s.downcase) &&
        tester.dig("attributes", "state") == "NOT_INVITED"
    end.each do |tester|
      client.post("/v1/betaTesterInvitations", {
        data: {
          type: "betaTesterInvitations",
          relationships: {
            app: { data: { type: "apps", id: app.fetch("id") } },
            betaTester: { data: { type: "betaTesters", id: tester.fetch("id") } }
          }
        }
      })
      external_invited_count += 1
    end
  end
end

localizations = client.get("/v1/builds/#{build_id}/betaBuildLocalizations", { "limit" => "20" }).fetch("data")
localization = localizations.find { |item| item.dig("attributes", "locale") == "zh-Hans" } || localizations.first
actual_whats_new = localization&.dig("attributes", "whatsNew").to_s
abort_release("What to Test 回读不一致") unless actual_whats_new == whats_new

puts "Mimitag TestFlight 内测发布成功：#{metadata[:version]} (#{metadata[:build]}) " \
     "build=#{build_id} group=#{group.dig('attributes', 'name')} testers=#{tester_count} " \
     "invitations=#{invited_count} whatsNew=verified external=#{external_state} " \
     "externalInvitations=#{external_invited_count}"
