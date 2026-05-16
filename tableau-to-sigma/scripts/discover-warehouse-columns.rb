#!/usr/bin/env ruby
# Fetch warehouse column metadata for one or more table inodeIds in parallel.
# Encapsulates the "response key is `entries`, not `columns`" gotcha and the
# Sigma auth refresh.
#
# Usage:
#   ruby discover-warehouse-columns.rb <out-dir> <inodeId> [<inodeId> ...]

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

OUT_DIR = ARGV.shift || abort('usage: discover-warehouse-columns.rb <out-dir> <inodeId>+')
INODES  = ARGV
abort 'no inodeIds given' if INODES.empty?

BASE = ENV.fetch('SIGMA_BASE_URL')
TOK  = ENV.fetch('SIGMA_API_TOKEN') { abort 'set SIGMA_API_TOKEN' }
FileUtils.mkdir_p(OUT_DIR)

def get(path)
  uri = URI("#{BASE}#{path}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{TOK}"
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }.body
end

threads = INODES.map do |inode|
  Thread.new do
    raw  = get("/v2/connections/tables/#{inode}/columns")
    body = JSON.parse(raw)
    cols = body['entries'] || []   # API gotcha: entries, not columns
    File.write("#{OUT_DIR}/#{inode}.json", JSON.pretty_generate(cols))
    [inode, cols.size]
  end
end

threads.each(&:join).map(&:value).each do |inode, n|
  puts "  #{inode}: #{n} columns"
end
