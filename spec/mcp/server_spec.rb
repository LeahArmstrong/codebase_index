# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/version'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/server'

RSpec.describe CodebaseIndex::MCP::Server do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:server) { described_class.build(index_dir: fixture_dir) }

  describe '.build' do
    it 'returns an MCP::Server' do
      expect(server).to be_a(::MCP::Server)
    end

    it 'registers 7 tools' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.size).to eq(7)
    end

    it 'registers expected tool names' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).to contain_exactly(
        'lookup', 'search', 'dependencies', 'dependents',
        'structure', 'graph_analysis', 'pagerank'
      )
    end

    it 'registers 2 resources' do
      resources = server.instance_variable_get(:@resources)
      expect(resources.size).to eq(2)
    end

    it 'registers expected resource URIs' do
      resources = server.instance_variable_get(:@resources)
      uris = resources.map(&:uri)
      expect(uris).to contain_exactly('codebase://manifest', 'codebase://graph')
    end
  end

  describe 'tool: lookup' do
    it 'returns unit data for a valid identifier' do
      response = call_tool(server, 'lookup', identifier: 'Post')
      data = parse_response(response)
      expect(data['identifier']).to eq('Post')
      expect(data['type']).to eq('model')
      expect(data['source_code']).to include('has_many')
    end

    it 'returns not found message for invalid identifier' do
      response = call_tool(server, 'lookup', identifier: 'NonExistent')
      expect(response_text(response)).to include('not found')
    end
  end

  describe 'tool: search' do
    it 'returns matching results' do
      response = call_tool(server, 'search', query: 'Post')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('Post')
    end

    it 'filters by type' do
      response = call_tool(server, 'search', query: 'Post', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end

    it 'respects limit' do
      response = call_tool(server, 'search', query: '.*', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end
  end

  describe 'tool: dependencies' do
    it 'returns forward dependencies' do
      response = call_tool(server, 'dependencies', identifier: 'Comment')
      data = parse_response(response)
      expect(data['root']).to eq('Comment')
      expect(data['nodes']['Comment']['deps']).to include('Post')
    end

    it 'returns empty for unknown identifier' do
      response = call_tool(server, 'dependencies', identifier: 'NonExistent')
      data = parse_response(response)
      expect(data['nodes']).to be_empty
    end
  end

  describe 'tool: dependents' do
    it 'returns reverse dependencies' do
      response = call_tool(server, 'dependents', identifier: 'Post')
      data = parse_response(response)
      expect(data['root']).to eq('Post')
      expect(data['nodes']['Post']['deps']).to include('Comment', 'PostsController')
    end
  end

  describe 'tool: structure' do
    it 'returns manifest by default' do
      response = call_tool(server, 'structure')
      data = parse_response(response)
      expect(data['manifest']).to include('rails_version' => '8.1.2')
    end

    it 'includes summary when detail is full' do
      response = call_tool(server, 'structure', detail: 'full')
      data = parse_response(response)
      expect(data['summary']).to include('Codebase Index Summary')
    end

    it 'excludes summary when detail is summary' do
      response = call_tool(server, 'structure', detail: 'summary')
      data = parse_response(response)
      expect(data).not_to have_key('summary')
    end
  end

  describe 'tool: graph_analysis' do
    it 'returns all sections by default' do
      response = call_tool(server, 'graph_analysis')
      data = parse_response(response)
      expect(data).to include('orphans', 'dead_ends', 'hubs', 'cycles')
    end

    it 'returns a specific section' do
      response = call_tool(server, 'graph_analysis', analysis: 'orphans')
      data = parse_response(response)
      expect(data).to have_key('orphans')
      expect(data['orphans']).to include('PostsController')
    end
  end

  describe 'tool: pagerank' do
    it 'returns ranked nodes with scores' do
      response = call_tool(server, 'pagerank')
      data = parse_response(response)
      expect(data['total_nodes']).to eq(3)
      expect(data['results']).to be_an(Array)
      expect(data['results'].first).to include('identifier', 'type', 'score')
    end

    it 'respects limit' do
      response = call_tool(server, 'pagerank', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end

    it 'filters by type' do
      response = call_tool(server, 'pagerank', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────────────────────

  # Call a tool on the server by name with the given arguments.
  # MCP stores tools as Hash<String, Class>.
  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  # Extract the text content from a tool response.
  def response_text(response)
    response.content.first[:text]
  end

  # Parse JSON from a tool response.
  def parse_response(response)
    JSON.parse(response_text(response))
  end
end
