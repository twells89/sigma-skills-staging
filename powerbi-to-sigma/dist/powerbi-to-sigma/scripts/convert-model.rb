#!/usr/bin/env ruby
# convert-model.rb — turn a Power BI model.bim into a postable Sigma DM spec.
#
# Power BI analog of the Tableau DM-build step. The actual TMSL→Sigma conversion
# is done by the `convert_powerbi_to_sigma` MCP tool (or the /tmp/conv-fix CLI
# build) — that's an agent/MCP call, not a library this script can import. So
# this script does the two deterministic halves that bracket the MCP call:
#
#   MODE A (--bim ...): print the exact MCP call the agent should make, and the
#   warehouse db/schema/connection it should pass. (Discovery + instruction.)
#
#   MODE B (--converter-out ...): take the MCP's sigmaDataModel JSON and apply
#   the 3 required spec fixups (refs/spec-fixups.md, gap beads-sigma-tkd) so it
#   is accepted by POST /v2/dataModels/spec:
#     1. schemaVersion: 1 at top level
#     2. folderId + ownerId harvested from a reference DM (find-or-pick-dm.rb)
#     3. element `name` on every base warehouse-table element (= source.path[-1]),
#        because workbook masters reference DM elements BY NAME.
#   Writes a ready-to-post spec. Does NOT post (post-and-readback.rb does that),
#   so the step is idempotent and re-runnable.
#
# Usage:
#   # A — emit the MCP instruction for a model.bim:
#   ruby scripts/convert-model.rb --bim /tmp/pbix/model.bim \
#       --connection <connUUID> --database <DB> --schema <SCHEMA>
#
#   # B — apply fixups to the converter output:
#   ruby scripts/convert-model.rb --converter-out /tmp/pbix/dm-raw.json \
#       --ref-dm <referenceDataModelId> \
#       --out /tmp/pbix/dm-spec.json
#       [--name "Workforce KitchenSink (from Power BI)"]
#       [--folder-id <uuid> --owner-id <id>]   # skip ref-dm harvest if both given
#
# Env (mode B harvest): SIGMA_BASE_URL + SIGMA_API_TOKEN.

require 'json'
require 'optparse'
require 'open3'

opts = {}
OptionParser.new do |p|
  p.on('--bim PATH')            { |v| opts[:bim] = v }
  p.on('--connection ID')       { |v| opts[:conn] = v }
  p.on('--database DB')         { |v| opts[:db] = v }
  p.on('--schema S')            { |v| opts[:schema] = v }
  p.on('--converter-out PATH')  { |v| opts[:cvt] = v }
  p.on('--ref-dm ID')           { |v| opts[:ref_dm] = v }
  p.on('--folder-id ID')        { |v| opts[:folder] = v }
  p.on('--owner-id ID')         { |v| opts[:owner] = v }
  p.on('--name NAME')           { |v| opts[:name] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
end.parse!

# ---- MODE A: emit the MCP conversion instruction --------------------------
if opts[:bim]
  abort('--bim not found: ' + opts[:bim]) unless File.exist?(opts[:bim])
  warn "=" * 64
  warn "convert-model.rb MODE A — run this MCP call to convert the model:"
  warn "=" * 64
  warn "  mcp__sigma-data-model__convert_powerbi_to_sigma"
  warn "    model_json    = <contents of #{opts[:bim]}>"
  warn "    connection_id = #{opts[:conn] || '<conn UUID, or \"\" to omit>'}"
  warn "    database      = #{opts[:db] || '<DB, or \"\" — needed for the M-Snowflake gap j89>'}"
  warn "    schema        = #{opts[:schema] || '<SCHEMA, or \"\">'}"
  warn ""
  warn "Save the tool's `sigmaDataModel` JSON to a file, then re-run:"
  warn "  ruby scripts/convert-model.rb --converter-out <that file> \\"
  warn "    --ref-dm <referenceDataModelId> --out /tmp/pbix/dm-spec.json"
  warn "=" * 64
  exit 0
end

# ---- MODE B: apply the 3 fixups -------------------------------------------
abort('mode B needs --converter-out and --out') unless opts[:cvt] && opts[:out]
raw = JSON.parse(File.read(opts[:cvt]))
# The MCP may wrap the spec as {sigmaDataModel: {...}} or return it bare.
dm = raw['sigmaDataModel'] || raw

# Harvest folderId/ownerId from a reference DM unless both supplied.
folder, owner = opts[:folder], opts[:owner]
if (folder.nil? || owner.nil?)
  abort('need --ref-dm (or both --folder-id and --owner-id)') unless opts[:ref_dm]
  base = ENV.fetch('SIGMA_BASE_URL'); tok = ENV.fetch('SIGMA_API_TOKEN')
  require 'net/http'; require 'uri'
  uri = URI("#{base}/v2/dataModels/#{opts[:ref_dm]}/spec")
  req = Net::HTTP::Get.new(uri); req['Authorization'] = "Bearer #{tok}"; req['Accept'] = 'application/json'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  abort("ref-dm spec fetch -> #{res.code}: #{res.body[0, 300]}") unless res.code.to_i == 200
  ref = JSON.parse(res.body)
  folder ||= ref['folderId']; owner ||= ref['ownerId']
  warn "[convert-model] harvested folderId=#{folder} ownerId=#{owner} from ref-dm #{opts[:ref_dm]}"
end

# Fixup 1: schemaVersion
dm['schemaVersion'] = 1
# Fixup 2: folderId + ownerId
dm['folderId'] = folder
dm['ownerId']  = owner
# Fixup 3: name base warehouse-table elements (= source.path[-1]) if unnamed.
named = 0
(dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    next if el['name'] && !el['name'].to_s.empty?
    path = el.dig('source', 'path')
    if path.is_a?(Array) && !path.empty?
      el['name'] = path[-1]
      named += 1
    end
  end
end
dm['name'] = opts[:name] if opts[:name]

File.write(opts[:out], JSON.pretty_generate(dm))
warn "[convert-model] fixups applied (schemaVersion=1, folderId/ownerId set, #{named} element name(s) added)"
warn "[convert-model] wrote #{opts[:out]} — post with:"
warn "  ruby scripts/post-and-readback.rb --type datamodel --spec #{opts[:out]}"
