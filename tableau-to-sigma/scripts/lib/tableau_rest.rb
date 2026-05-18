# Tableau REST API wrapper for tableau-to-sigma when the MCP isn't available.
# Requires TABLEAU_SERVER_URL, TABLEAU_SITE_ID, TABLEAU_AUTH_TOKEN, TABLEAU_API_VERSION in ENV
# (set by scripts/get-tableau-token.sh).
#
# All methods return parsed Hash/Array (or raw bytes for view_image). Network/HTTP errors raise
# Tableau::Error with the response body included.

require 'net/http'
require 'uri'
require 'json'
require 'cgi'

module Tableau
  class Error < StandardError; end

  module_function

  def server_url
    ENV.fetch('TABLEAU_SERVER_URL') { raise Error, 'TABLEAU_SERVER_URL not set — run get-tableau-token.sh' }
  end

  def site_id
    ENV.fetch('TABLEAU_SITE_ID') { raise Error, 'TABLEAU_SITE_ID not set — run get-tableau-token.sh' }
  end

  def auth_token
    ENV.fetch('TABLEAU_AUTH_TOKEN') { raise Error, 'TABLEAU_AUTH_TOKEN not set — run get-tableau-token.sh' }
  end

  def api_version
    ENV.fetch('TABLEAU_API_VERSION', '3.22')
  end

  def base_path
    "/api/#{api_version}/sites/#{site_id}"
  end

  # ---- low-level transport -------------------------------------------------

  def request(method, path, body: nil, content_type: 'application/json', accept: 'application/json', binary: false)
    uri = URI.join(server_url, path)
    req = case method
          when :get  then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          when :put  then Net::HTTP::Put.new(uri)
          when :delete then Net::HTTP::Delete.new(uri)
          else raise ArgumentError, "unsupported method #{method}"
          end
    req['X-Tableau-Auth'] = auth_token
    req['Accept'] = accept
    if body
      req['Content-Type'] = content_type
      req.body = body
    end

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) do |http|
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "#{method.upcase} #{path} -> #{res.code} #{res.message}\n#{res.body}"
      end
      return res.body if binary
      # Only JSON-parse when we explicitly asked for JSON.
      return res.body unless accept == 'application/json'
      res.body.empty? ? nil : JSON.parse(res.body)
    end
  end

  # ---- workbooks -----------------------------------------------------------

  # Returns the first workbook matching name, or nil. Use search_workbooks for full list.
  def find_workbook_by_name(name)
    encoded = CGI.escape("name:eq:#{name}")
    j = request(:get, "#{base_path}/workbooks?filter=#{encoded}")
    list = j.dig('workbooks', 'workbook') || []
    list = [list] unless list.is_a?(Array)
    list.first
  end

  def get_workbook(workbook_id)
    request(:get, "#{base_path}/workbooks/#{workbook_id}")['workbook']
  end

  # Returns the raw .twb XML (string) or .twbx bytes for workbooks with embedded extracts.
  # Embedded check: if the response starts with PK\x03\x04 it's a zip (twbx); otherwise raw XML.
  def download_workbook_content(workbook_id, include_extract: false)
    qs = include_extract ? '' : '?includeExtract=false'
    request(:get, "#{base_path}/workbooks/#{workbook_id}/content#{qs}",
            accept: '*/*', binary: true)
  end

  # ---- views ---------------------------------------------------------------

  def view_data(view_id)
    request(:get, "#{base_path}/views/#{view_id}/data", accept: '*/*')
  end

  def view_image(view_id, width: 1400, height: 900, resolution: 'high')
    qs = "?resolution=#{resolution}&maxAge=1"
    qs += "&vf_width=#{width}&vf_height=#{height}" if width && height
    request(:get, "#{base_path}/views/#{view_id}/image#{qs}", accept: '*/*', binary: true)
  end

  # ---- datasources ---------------------------------------------------------

  def list_datasources(page_size: 100, page: 1)
    request(:get, "#{base_path}/datasources?pageSize=#{page_size}&pageNumber=#{page}")
  end

  def find_datasource_by_name(name)
    encoded = CGI.escape("name:eq:#{name}")
    j = request(:get, "#{base_path}/datasources?filter=#{encoded}")
    list = j.dig('datasources', 'datasource') || []
    list = [list] unless list.is_a?(Array)
    list.first
  end

  # VizQL Data Service — full field list with calc formulas. This is the REST equivalent
  # of mcp__tableau__get-datasource-metadata.
  def read_metadata(datasource_luid)
    body = { datasource: { datasourceLuid: datasource_luid } }.to_json
    request(:post, "/api/v1/vizql-data-service/read-metadata", body: body)
  end

  # ---- metadata GraphQL ----------------------------------------------------

  # Convenience: fetch a published datasource by luid, returning fields + calc formulas.
  # Cleaner display names than read_metadata (which uses GUIDs for fields belonging to
  # joined logical tables).
  def graphql_datasource_fields(datasource_luid)
    query = <<~GQL
      {
        publishedDatasources(filter:{luid:"#{datasource_luid}"}) {
          name luid
          fields {
            name
            fullyQualifiedName
            ... on CalculatedField { formula isHidden }
          }
        }
      }
    GQL
    body = { query: query }.to_json
    request(:post, "/api/metadata/graphql", body: body)
  end

  def graphql(query, variables: nil)
    payload = { query: query }
    payload[:variables] = variables if variables
    request(:post, "/api/metadata/graphql", body: payload.to_json)
  end
end
