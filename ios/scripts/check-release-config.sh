#!/usr/bin/env bash
#
# Fails when the Release configuration of the Stexx app target (ios/project.yml) would ship something meant for
# development:
#   - STEXX_USE_MOCK_API is anything but NO (the app falls back to the mock backend unless the value is "NO"),
#   - STEXX_API_BASE_URL is not https, or points at this machine,
#   - STEXX_ATTESTATION_MODE is not "attest" (dev-bypass only works against a dev server),
#   - STEXX_ATS_ALLOWS_LOCAL_NETWORKING is YES.
#
# Values resolve the way XcodeGen does for one target: target configs[Release] > target base > project
# configs[Release] > project base. Every configuration of type `release` is checked.
#
#   ios/scripts/check-release-config.sh [path/to/project.yml] [target]
#
# CI runs it in .github/workflows/server.yml as an advisory job (continue-on-error) until the owner flips
# STEXX_USE_MOCK_API to NO for Release; then it can become blocking. Needs only ruby (stdlib YAML).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="${1:-$here/../project.yml}"
target="${2:-Stexx}"

[ -f "$project" ] || { echo "check-release-config: $project not found" >&2; exit 2; }
command -v ruby >/dev/null || { echo "check-release-config: ruby is required" >&2; exit 2; }

exec ruby -ryaml -e '
  path, target = ARGV
  doc = YAML.safe_load(File.read(path), aliases: true) || {}

  # XcodeGen settings: either {base:, configs:, groups:} or a flat hash that is all base.
  def split(settings)
    settings ||= {}
    if settings.key?("base") || settings.key?("configs") || settings.key?("groups")
      [settings["base"] || {}, settings["configs"] || {}]
    else
      [settings, {}]
    end
  end

  def for_config(configs, name)
    configs.each { |k, v| return v || {} if k.to_s.casecmp?(name) }
    {}
  end

  def norm(v)
    case v
    when true then "YES"
    when false then "NO"
    when nil then nil
    else v.to_s
    end
  end

  t = (doc["targets"] || {})[target] or abort("check-release-config: no target #{target} in #{path}")
  t_base, t_configs = split(t["settings"])
  p_base, p_configs = split(doc["settings"])
  release = (doc["configs"] || { "Release" => "release" }).select { |_, type| type.to_s == "release" }.keys
  abort("check-release-config: no configuration of type release in #{path}") if release.empty?

  failures = []
  release.each do |config|
    layers = [for_config(t_configs, config), t_base, for_config(p_configs, config), p_base]
    get = ->(key) { layers.each { |l| return norm(l[key]) if l.key?(key) }; nil }

    mock = get.("STEXX_USE_MOCK_API")
    failures << "#{config}: STEXX_USE_MOCK_API is #{mock.nil? ? "unset" : mock.inspect}; it must be NO, or the app ships talking to the mock backend" unless mock.to_s.casecmp?("NO")

    url = get.("STEXX_API_BASE_URL")
    if url.nil? || !url.start_with?("https://") || url =~ %r{\Ahttps://(127\.|localhost|\[::1\]|0\.0\.0\.0)}
      failures << "#{config}: STEXX_API_BASE_URL is #{url.inspect}; it must be the public https API"
    end

    att = get.("STEXX_ATTESTATION_MODE")
    failures << "#{config}: STEXX_ATTESTATION_MODE is #{att.inspect}; it must be attest" unless att == "attest"

    ats = get.("STEXX_ATS_ALLOWS_LOCAL_NETWORKING")
    failures << "#{config}: STEXX_ATS_ALLOWS_LOCAL_NETWORKING is YES; local HTTP must stay out of shipped builds" if ats.to_s.casecmp?("YES")
  end

  if failures.empty?
    puts "check-release-config: #{release.join(", ")} OK for target #{target}"
  else
    failures.each { |f| puts(ENV["GITHUB_ACTIONS"] == "true" ? "::error file=ios/project.yml,title=Release config::#{f}" : "error: #{f}") }
    exit 1
  end
' "$project" "$target"
