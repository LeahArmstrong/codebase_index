# frozen_string_literal: true

require 'mcp'
require_relative 'index_reader'

module CodebaseIndex
  module MCP
    # Builds an MCP::Server with 7 tools and 2 resources for querying
    # CodebaseIndex extraction output.
    #
    # All tools are defined inline via closures over an IndexReader instance.
    # No Rails required at runtime — reads JSON files from disk.
    #
    # @example
    #   server = CodebaseIndex::MCP::Server.build(index_dir: "/path/to/output")
    #   transport = MCP::Server::Transports::StdioTransport.new(server)
    #   transport.open
    #
    module Server
      class << self
        # Build a configured MCP::Server with all tools and resources.
        #
        # @param index_dir [String] Path to extraction output directory
        # @return [MCP::Server] Configured server ready for transport
        def build(index_dir:)
          reader = IndexReader.new(index_dir)
          resources = build_resources

          # Lambda captured by all tool blocks for building responses.
          respond = method(:text_response)

          server = ::MCP::Server.new(
            name: 'codebase-index',
            version: CodebaseIndex::VERSION,
            resources: resources
          )

          define_lookup_tool(server, reader, respond)
          define_search_tool(server, reader, respond)
          define_dependencies_tool(server, reader, respond)
          define_dependents_tool(server, reader, respond)
          define_structure_tool(server, reader, respond)
          define_graph_analysis_tool(server, reader, respond)
          define_pagerank_tool(server, reader, respond)
          register_resource_handler(server, reader)

          server
        end

        private

        def text_response(text)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }])
        end

        def define_lookup_tool(server, reader, respond)
          server.define_tool(
            name: 'lookup',
            description: 'Look up a code unit by its exact identifier. Returns full source code, metadata, dependencies, and dependents.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Exact unit identifier (e.g. "Post", "PostsController", "Api::V1::HealthController")' }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:|
            unit = reader.find_unit(identifier)
            if unit
              respond.call(JSON.pretty_generate(unit))
            else
              respond.call("Unit not found: #{identifier}")
            end
          end
        end

        def define_search_tool(server, reader, respond)
          server.define_tool(
            name: 'search',
            description: 'Search code units by pattern. Matches against identifiers by default; can also search source_code and metadata fields.',
            input_schema: {
              properties: {
                query: { type: 'string', description: 'Search pattern (case-insensitive regex)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types: model, controller, service, job, mailer, etc.'
                },
                fields: {
                  type: 'array', items: { type: 'string' },
                  description: 'Fields to search: identifier, source_code, metadata. Default: [identifier]'
                },
                limit: { type: 'integer', description: 'Maximum results (default: 20)' }
              },
              required: ['query']
            }
          ) do |query:, types: nil, fields: nil, limit: nil, server_context:|
            results = reader.search(
              query,
              types: types,
              fields: fields || %w[identifier],
              limit: limit || 20
            )
            respond.call(JSON.pretty_generate({
              query: query,
              result_count: results.size,
              results: results
            }))
          end
        end

        def define_dependencies_tool(server, reader, respond)
          server.define_tool(
            name: 'dependencies',
            description: 'Traverse forward dependencies of a unit (what it depends on). Returns a BFS tree with depth.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier to start from' },
                depth: { type: 'integer', description: 'Maximum traversal depth (default: 2)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, depth: nil, types: nil, server_context:|
            result = reader.traverse_dependencies(
              identifier,
              depth: depth || 2,
              types: types
            )
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_dependents_tool(server, reader, respond)
          server.define_tool(
            name: 'dependents',
            description: 'Traverse reverse dependencies of a unit (what depends on it). Returns a BFS tree with depth.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier to start from' },
                depth: { type: 'integer', description: 'Maximum traversal depth (default: 2)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, depth: nil, types: nil, server_context:|
            result = reader.traverse_dependents(
              identifier,
              depth: depth || 2,
              types: types
            )
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_structure_tool(server, reader, respond)
          server.define_tool(
            name: 'structure',
            description: 'Get codebase structure overview. Returns manifest (counts, versions, git info) and optionally the full summary.',
            input_schema: {
              properties: {
                detail: {
                  type: 'string', enum: %w[summary full],
                  description: '"summary" for manifest only, "full" to include SUMMARY.md. Default: summary'
                }
              }
            }
          ) do |detail: nil, server_context:|
            result = { manifest: reader.manifest }
            if (detail || 'summary') == 'full'
              result[:summary] = reader.summary
            end
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_graph_analysis_tool(server, reader, respond)
          server.define_tool(
            name: 'graph_analysis',
            description: 'Get structural analysis of the dependency graph: orphans, dead ends, hubs, cycles, and bridges.',
            input_schema: {
              properties: {
                analysis: {
                  type: 'string',
                  enum: %w[orphans dead_ends hubs cycles bridges all],
                  description: 'Which analysis to return. Default: all'
                },
                limit: { type: 'integer', description: 'Limit results for hubs/bridges (default: 20)' }
              }
            }
          ) do |analysis: nil, limit: nil, server_context:|
            data = reader.graph_analysis
            section = analysis || 'all'

            result = if section == 'all'
                       data
                     else
                       { section => data[section], 'stats' => data['stats'] }
                     end

            # Apply limit to array sections
            if limit && result[section].is_a?(Array)
              result = result.dup
              result[section] = result[section].first(limit)
            end

            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_pagerank_tool(server, reader, respond)
          server.define_tool(
            name: 'pagerank',
            description: 'Get PageRank importance scores for code units. Higher scores indicate more structurally important nodes.',
            input_schema: {
              properties: {
                limit: { type: 'integer', description: 'Maximum results to return (default: 20)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              }
            }
          ) do |limit: nil, types: nil, server_context:|
            scores = reader.dependency_graph.pagerank
            graph_data = reader.raw_graph_data
            nodes = graph_data['nodes'] || {}

            type_set = types&.to_set

            ranked = scores
                     .sort_by { |_id, score| -score }
                     .filter_map do |id, score|
                       node_type = nodes.dig(id, 'type')
                       next if type_set && !type_set.include?(node_type)

                       { identifier: id, type: node_type, score: score.round(6) }
                     end

            effective_limit = limit || 20
            result = {
              total_nodes: scores.size,
              results: ranked.first(effective_limit)
            }
            respond.call(JSON.pretty_generate(result))
          end
        end

        def build_resources
          [
            ::MCP::Resource.new(
              uri: 'codebase://manifest',
              name: 'manifest',
              description: 'Extraction manifest with version info, unit counts, and git metadata',
              mime_type: 'application/json'
            ),
            ::MCP::Resource.new(
              uri: 'codebase://graph',
              name: 'dependency-graph',
              description: 'Full dependency graph with nodes, edges, and type index',
              mime_type: 'application/json'
            )
          ]
        end

        def register_resource_handler(server, reader)
          server.resources_read_handler do |params|
            uri = params[:uri]
            case uri
            when 'codebase://manifest'
              [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(reader.manifest) }]
            when 'codebase://graph'
              [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(reader.raw_graph_data) }]
            else
              [{ uri: uri, mimeType: 'text/plain', text: "Unknown resource: #{uri}" }]
            end
          end
        end
      end
    end
  end
end
