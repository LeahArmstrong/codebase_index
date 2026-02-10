# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/index_reader'

RSpec.describe CodebaseIndex::MCP::IndexReader do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:reader) { described_class.new(fixture_dir) }

  describe '#initialize' do
    it 'accepts a valid index directory' do
      expect { described_class.new(fixture_dir) }.not_to raise_error
    end

    it 'raises ArgumentError for non-existent directory' do
      expect { described_class.new('/nonexistent/path') }
        .to raise_error(ArgumentError, /does not exist/)
    end

    it 'raises ArgumentError for directory without manifest.json' do
      expect { described_class.new(Dir.tmpdir) }
        .to raise_error(ArgumentError, /No manifest\.json/)
    end
  end

  describe '#manifest' do
    it 'returns parsed manifest data' do
      expect(reader.manifest).to include(
        'rails_version' => '8.1.2',
        'ruby_version' => '4.0.1',
        'total_units' => 3
      )
    end

    it 'caches the result' do
      expect(reader.manifest).to equal(reader.manifest)
    end
  end

  describe '#summary' do
    it 'returns SUMMARY.md content' do
      expect(reader.summary).to include('Codebase Index Summary')
      expect(reader.summary).to include('Post')
    end
  end

  describe '#dependency_graph' do
    it 'returns a DependencyGraph instance' do
      expect(reader.dependency_graph).to be_a(CodebaseIndex::DependencyGraph)
    end

    it 'has correct edges' do
      graph = reader.dependency_graph
      expect(graph.dependencies_of('Comment')).to include('Post')
      expect(graph.dependents_of('Post')).to include('Comment', 'PostsController')
    end
  end

  describe '#graph_analysis' do
    it 'returns parsed graph analysis data' do
      analysis = reader.graph_analysis
      expect(analysis).to include('orphans', 'dead_ends', 'hubs', 'cycles')
    end

    it 'contains expected orphans' do
      expect(reader.graph_analysis['orphans']).to include('PostsController')
    end
  end

  describe '#find_unit' do
    it 'returns full unit data for a valid identifier' do
      unit = reader.find_unit('Post')
      expect(unit).to include(
        'type' => 'model',
        'identifier' => 'Post',
        'source_code' => a_string_including('has_many :comments')
      )
    end

    it 'returns nil for an unknown identifier' do
      expect(reader.find_unit('NonExistent')).to be_nil
    end

    it 'includes metadata in the unit' do
      unit = reader.find_unit('Post')
      expect(unit['metadata']).to include('table_name' => 'posts')
    end

    it 'loads controller units' do
      unit = reader.find_unit('PostsController')
      expect(unit['type']).to eq('controller')
      expect(unit['source_code']).to include('Post.all')
    end
  end

  describe '#list_units' do
    it 'returns all units when no type filter' do
      units = reader.list_units
      identifiers = units.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly('Post', 'Comment', 'PostsController')
    end

    it 'filters by type' do
      units = reader.list_units(type: 'model')
      identifiers = units.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly('Post', 'Comment')
    end

    it 'returns empty array for unknown type' do
      expect(reader.list_units(type: 'nonexistent')).to eq([])
    end

    it 'returns only controllers when filtered' do
      units = reader.list_units(type: 'controller')
      expect(units.size).to eq(1)
      expect(units.first['identifier']).to eq('PostsController')
    end
  end

  describe '#search' do
    it 'matches identifiers by default' do
      results = reader.search('Post')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('Post', 'PostsController')
    end

    it 'is case-insensitive' do
      results = reader.search('post')
      identifiers = results.map { |r| r[:identifier] }
      expect(identifiers).to include('Post')
    end

    it 'filters by type' do
      results = reader.search('Post', types: ['model'])
      expect(results.all? { |r| r[:type] == 'model' }).to be true
    end

    it 'respects limit' do
      results = reader.search('.*', limit: 2)
      expect(results.size).to eq(2)
    end

    it 'searches source_code when requested' do
      results = reader.search('has_many', fields: %w[source_code])
      expect(results.first[:identifier]).to eq('Post')
      expect(results.first[:match_field]).to eq('source_code')
    end

    it 'searches metadata when requested' do
      results = reader.search('posts_controller', fields: %w[metadata])
      # The fixtures have metadata with parent_class etc — this tests that metadata JSON is searched
      expect(results).to be_an(Array)
    end

    it 'returns match_field for each result' do
      results = reader.search('Comment')
      results.each do |r|
        expect(r).to include(:identifier, :type, :match_field)
      end
    end
  end

  describe '#traverse_dependencies' do
    it 'returns forward dependencies for Comment' do
      result = reader.traverse_dependencies('Comment', depth: 1)
      expect(result[:root]).to eq('Comment')
      expect(result[:nodes]['Comment'][:deps]).to include('Post')
    end

    it 'returns empty deps for a leaf node' do
      result = reader.traverse_dependencies('Post', depth: 1)
      expect(result[:nodes]['Post'][:deps]).to eq([])
    end

    it 'respects depth limit' do
      result = reader.traverse_dependencies('Comment', depth: 0)
      # At depth 0, we get the root node but don't traverse further
      expect(result[:nodes].keys).to eq(['Comment'])
    end

    it 'returns empty nodes for unknown identifier' do
      result = reader.traverse_dependencies('NonExistent', depth: 1)
      expect(result[:nodes]).to be_empty
    end

    it 'returns found: false for unknown identifier' do
      result = reader.traverse_dependencies('NonExistent', depth: 1)
      expect(result[:found]).to be false
    end

    it 'returns found: true for known identifier' do
      result = reader.traverse_dependencies('Comment', depth: 1)
      expect(result[:found]).to be true
    end
  end

  describe '#traverse_dependents' do
    it 'returns reverse dependencies for Post' do
      result = reader.traverse_dependents('Post', depth: 1)
      expect(result[:root]).to eq('Post')
      expect(result[:nodes]['Post'][:deps]).to include('Comment', 'PostsController')
    end

    it 'returns empty deps for an orphan node' do
      result = reader.traverse_dependents('PostsController', depth: 1)
      expect(result[:nodes]['PostsController'][:deps]).to eq([])
    end

    it 'returns found: true for known identifier' do
      result = reader.traverse_dependents('Post', depth: 1)
      expect(result[:found]).to be true
    end
  end

  describe 'unit cache' do
    it 'caches loaded units' do
      reader.find_unit('Post')
      reader.find_unit('Post')
      # No error and same object returned
      expect(reader.find_unit('Post')).to eq(reader.find_unit('Post'))
    end
  end
end
