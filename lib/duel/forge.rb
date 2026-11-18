# frozen_string_literal: true

require "json"
require "net/http"
require_relative "spawn"

module Duel
  # What the commands that run in CI's jobs of their own (Comment,
  # MarkPassed, Badge) share: GitHub's API, through gh, and GitLab's,
  # over HTTP, each saying why what it asked failed, as the command
  # (#command) it's for. An includer has @env and @err, and names its
  # GitLab token (#gitlab_token).
  # @api private
  module Forge
    private

    # What gh api prints, given +args+ (and +input+ on its standard
    # input), or nil where it fails (or isn't there), which it says why,
    # unless +quiet+ (where failing says what's there, a branch that
    # isn't, say).
    def gh(*args, quiet: false)
      out, err, status = Spawn.open3(:capture3, "gh", "api", *args)
      return out if status.success?

      @err.puts "#{command}: gh api #{args.first}: #{err.strip}" unless quiet
    rescue SystemCallError => e
      @err.puts "#{command}: gh: #{e}"
    end

    # What GitLab's API says to +verb+ (:Get, :Post or :Delete) +path+
    # (under CI_API_V4_URL), given +body+ (as JSON), signed in with
    # #gitlab_token, or nil where it fails, which it says why, unless
    # +quiet+. With +pages+, that and the next page's number
    # (X-Next-Page), if there's one.
    def gitlab(verb, path, body = nil, pages: false, quiet: false)
      uri = URI("#{@env.fetch("CI_API_V4_URL")}#{path}")
      request = Net::HTTP.const_get(verb).new(uri)
      request["PRIVATE-TOKEN"] = @env.fetch(gitlab_token)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      http = connection(uri)
      http.use_ssl = uri.scheme == "https"
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        return if quiet

        return @err.puts("#{command}: GitLab: #{verb.upcase} #{path}: #{[response.code, response.body.to_s.strip].reject(&:empty?).join(" ")}")
      end

      text = response.body.to_s
      none = {} #: Hash[String, untyped]
      # (Nothing, as a deletion says.)
      parsed = text.empty? ? none : JSON.parse(text)
      pages ? [parsed, response["X-Next-Page"].to_s[/\A[0-9]+\z/]] : parsed
    rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError => e
      @err.puts "#{command}: GitLab: #{verb.upcase} #{path}: #{e}"
    end

    # Names the branch (of those +branch+'s name is in, which the block
    # says is there) that keeps Git from making +branch+: a branch named
    # duel blocks duel/passed/main. Returns 1.
    def blocked(branch)
      prefixes = branch.split("/").then { |parts| (1...parts.size).map { |n| parts.first(n).join("/") } }
      prefixes.reverse_each.select { |prefix| yield(prefix) }.each do |prefix|
        @out.puts "#{"::error::" unless gitlab?}The branch #{prefix} keeps Duel from making #{branch}, as Git can't have both. " \
          "Delete it (git push origin --delete #{prefix}), or rename it."
      end
      1
    end

    # A connection to +uri+'s host, not yet started.
    # mutant:disable -- a nil host is Net::HTTP's localhost, where the
    # tests' server is, so only another host could tell them apart
    def connection(uri) = Net::HTTP.new(uri.host.to_s, uri.port)

    # Whether it runs on GitLab CI (GITLAB_CI, set and not empty).
    def gitlab? = !@env["GITLAB_CI"].to_s.empty?

    def repository = @env.fetch("GITHUB_REPOSITORY")

    # The project's path in GitLab's API.
    def project = "/projects/#{@env.fetch("CI_PROJECT_ID")}"

    # +ref+, as a path of GitLab's API takes a branch's name.
    def encoded(ref) = ref.gsub("/", "%2F")
  end
end
