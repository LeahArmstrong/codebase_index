# frozen_string_literal: true

# CodebaseIndex - Rails Codebase Indexing and Retrieval
#
# A system for extracting, indexing, and retrieving context from Rails codebases
# to enable AI-assisted development, debugging, and analytics.
#
# ## Quick Start
#
#   # Extract codebase
#   CodebaseIndex.extract!
#
#   # Or via rake
#   bundle exec rake codebase_index:extract
#
# ## Configuration
#
#   CodebaseIndex.configure do |config|
#     config.output_dir = Rails.root.join("tmp/codebase_index")
#     config.max_context_tokens = 8000
#     config.include_framework_sources = true
#   end
#
module CodebaseIndex
  VERSION = "0.1.0"

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ExtractionError < Error; end

  # ════════════════════════════════════════════════════════════════════════
  # Configuration
  # ════════════════════════════════════════════════════════════════════════

  class Configuration
    attr_accessor :output_dir, :embedding_model, :max_context_tokens,
                  :similarity_threshold, :include_framework_sources,
                  :gem_configs, :extractors

    def initialize
      @output_dir = defined?(Rails) ? Rails.root.join("tmp/codebase_index") : "tmp/codebase_index"
      @embedding_model = "text-embedding-3-small"
      @max_context_tokens = 8000
      @similarity_threshold = 0.7
      @include_framework_sources = true
      @gem_configs = {}
      @extractors = %i[models controllers services components]
    end

    # Add a gem to be indexed
    #
    # @param gem_name [String] Name of the gem
    # @param paths [Array<String>] Relative paths within the gem to index
    # @param priority [Symbol] :high, :medium, or :low
    def add_gem(gem_name, paths:, priority: :medium)
      @gem_configs[gem_name] = { paths: paths, priority: priority }
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Module Interface
  # ════════════════════════════════════════════════════════════════════════

  class << self
    attr_accessor :configuration

    def configure
      self.configuration ||= Configuration.new
      yield(configuration) if block_given?
      configuration
    end

    # Perform full extraction
    #
    # @param output_dir [String] Override output directory
    # @return [Hash] Extraction results
    def extract!(output_dir: nil)
      require_relative "codebase_index/extractor"

      dir = output_dir || configuration.output_dir
      extractor = Extractor.new(output_dir: dir)
      extractor.extract_all
    end

    # Perform incremental extraction
    #
    # @param changed_files [Array<String>] List of changed files
    # @return [Array<String>] Re-extracted unit identifiers
    def extract_changed!(changed_files)
      require_relative "codebase_index/extractor"

      extractor = Extractor.new(output_dir: configuration.output_dir)
      extractor.extract_changed(changed_files)
    end
  end

  # Initialize with defaults
  configure
end
