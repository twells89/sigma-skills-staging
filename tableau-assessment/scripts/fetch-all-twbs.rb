#!/usr/bin/env ruby
# Fetch the .twb (or .twbx, auto-unzipped) for every workbook on the current
# Tableau site, in parallel.
#
# Requires PAT-mode auth (TABLEAU_AUTH_TOKEN, TABLEAU_SITE_ID, TABLEAU_SERVER_URL).
# Run `eval "$(scripts/get-tableau-token.sh)"` in the same shell first.
#
# Usage:
#   ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site>
#
# Output:
#   <out>/twbs/<luid>.twb   — raw XML, ready for scan-workbook-gaps.rb
#   <out>/twbs/<luid>.twbx  — only present when server returned a .twbx (unzipped to .twb alongside)
#   <out>/workbook-list.json
#   <out>/twb-fetch-results.json

require 'json'
require 'fileutils'
require 'optparse'
require 'thread'
$LOAD_PATH.unshift File.expand_path('../../tableau-to-sigma/scripts/lib', __dir__)
require 'tableau_rest'

opts = { threads: 6 }
OptionParser.new do |p|
  p.on('--out DIR')        { |v| opts[:out] = v }
  p.on('--threads N', Integer) { |v| opts[:threads] = v }
end.parse!
abort('--out required') unless opts[:out]

twb_dir = File.join(opts[:out], 'twbs')
FileUtils.mkdir_p(twb_dir)

warn "Listing workbooks via REST..."
all_wbs = []
page = 1
loop do
  resp = Tableau.request(:get, "#{Tableau.base_path}/workbooks?pageSize=100&pageNumber=#{page}")
  batch = resp.dig('workbooks', 'workbook') || []
  all_wbs.concat(batch)
  pag = resp['pagination'] || {}
  break if batch.empty? || all_wbs.size >= pag['totalAvailable'].to_i
  page += 1
end
warn "got #{all_wbs.size} workbooks"
File.write(File.join(opts[:out], 'workbook-list.json'), JSON.pretty_generate(all_wbs))

queue = Queue.new
all_wbs.each { |w| queue << w }
results = {}
mutex = Mutex.new

threads = opts[:threads].times.map do
  Thread.new do
    while !queue.empty?
      w = queue.pop(true) rescue nil
      break unless w
      luid = w['id']
      name = w['name']
      begin
        bytes = Tableau.download_workbook_content(luid)
        path =
          if bytes[0, 2] == 'PK'
            File.join(twb_dir, "#{luid}.twbx")
          else
            File.join(twb_dir, "#{luid}.twb")
          end
        File.binwrite(path, bytes)
        mutex.synchronize do
          results[luid] = {
            'name' => name,
            'path' => path,
            'size' => bytes.bytesize,
            'kind' => path.end_with?('.twbx') ? 'twbx' : 'twb'
          }
          warn "  #{path}  (#{bytes.bytesize} bytes)  #{name}"
        end
      rescue => e
        mutex.synchronize do
          results[luid] = { 'name' => name, 'error' => e.message }
          warn "  ERROR #{luid}  #{name}: #{e.message}"
        end
      end
    end
  end
end
threads.each(&:join)

# Unzip .twbx → inner .twb (gap-scanner reads .twb XML directly)
results.each do |luid, r|
  next if r['error'] || r['kind'] != 'twbx'
  tmp = File.join(twb_dir, "_unpack_#{luid}")
  FileUtils.mkdir_p(tmp)
  unless system('unzip', '-o', '-q', r['path'], '-d', tmp)
    warn "  unzip failed for #{r['path']} (is the unzip command available?)"
    FileUtils.rm_rf(tmp)
    next
  end
  inner = Dir.glob(File.join(tmp, '**', '*.twb')).first
  if inner
    twb_path = File.join(twb_dir, "#{luid}.twb")
    FileUtils.cp(inner, twb_path)
    r['twb_path'] = twb_path
    r['twb_size'] = File.size(twb_path)
  end
  FileUtils.rm_rf(tmp)
end

File.write(File.join(opts[:out], 'twb-fetch-results.json'), JSON.pretty_generate(results))
n_err = results.count { |_, r| r['error'] }
warn "done. wrote twb-fetch-results.json (#{results.size} workbooks, #{n_err} errors)"
exit(n_err.positive? && results.size == n_err ? 1 : 0)
