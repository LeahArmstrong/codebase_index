# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "open3"
require "pathname"

require_relative "extracted_unit"
require_relative "dependency_graph"
require_relative "extractors/model_extractor"
require_relative "extractors/controller_extractor"
require_relative "extractors/phlex_extractor"
require_relative "extractors/service_extractor"
require_relative "extractors/job_extractor"
require_relative "extractors/mailer_extractor"
require_relative "extractors/graphql_extractor"
require_relative "extractors/rails_source_extractor"
require_relative "graph_analyzer"

module CodebaseIndex
  # Extractor is the main orchestrator for codebase extraction.
  #
  # It coordinates all individual extractors, builds the dependency graph,
  # enriches with git data, and outputs structured JSON for the indexing pipeline.
  #
  # @example Full extraction
  #   extractor = Extractor.new(output_dir: "tmp/codebase_index")
  #   results = extractor.extract_all
  #
  # @example Incremental extraction (for CI)
  #   extractor = Extractor.new
  #   extractor.extract_changed(["app/models/user.rb", "app/services/checkout.rb"])
  #
  class Extractor
    EXTRACTORS = {
      models: Extractors::ModelExtractor,
      controllers: Extractors::ControllerExtractor,
      graphql: Extractors::GraphQLExtractor,
      components: Extractors::PhlexExtractor,
      services: Extractors::ServiceExtractor,
      jobs: Extractors::JobExtractor,
      mailers: Extractors::MailerExtractor,
      rails_source: Extractors::RailsSourceExtractor
    }.freeze

    attr_reader :output_dir, :dependency_graph

    def initialize(output_dir: nil)
      @output_dir = Pathname.new(output_dir || Rails.root.join("tmp/codebase_index"))
      @dependency_graph = DependencyGraph.new
      @results = {}
    end

    # ══════════════════════════════════════════════════════════════════════
    # Full Extraction
    # ══════════════════════════════════════════════════════════════════════

    # Perform full extraction of the codebase
    #
    # @return [Hash] Results keyed by extractor type
    def extract_all
      setup_output_directory

      # Eager load once — all extractors need loaded classes for introspection
      Rails.application.eager_load!

      # Phase 1: Extract all units
      EXTRACTORS.each do |type, extractor_class|
        Rails.logger.info "[CodebaseIndex] Extracting #{type}..."
        start_time = Time.current

        extractor = extractor_class.new
        units = extractor.extract_all

        @results[type] = units

        elapsed = Time.current - start_time
        Rails.logger.info "[CodebaseIndex] Extracted #{units.size} #{type} in #{elapsed.round(2)}s"

        # Register in dependency graph
        units.each { |unit| @dependency_graph.register(unit) }
      end

      # Phase 2: Resolve dependents (reverse dependencies)
      Rails.logger.info "[CodebaseIndex] Resolving dependents..."
      resolve_dependents

      # Phase 3: Graph analysis (PageRank, structural metrics)
      Rails.logger.info "[CodebaseIndex] Analyzing dependency graph..."
      @graph_analysis = GraphAnalyzer.new(@dependency_graph).analyze

      # Phase 4: Enrich with git data
      Rails.logger.info "[CodebaseIndex] Enriching with git data..."
      enrich_with_git_data

      # Phase 5: Write output
      Rails.logger.info "[CodebaseIndex] Writing output..."
      write_results
      write_dependency_graph
      write_graph_analysis
      write_manifest
      write_structural_summary

      log_summary

      @results
    end

    # ══════════════════════════════════════════════════════════════════════
    # Incremental Extraction
    # ══════════════════════════════════════════════════════════════════════

    # Extract only units affected by changed files
    # Used for incremental indexing in CI
    #
    # @param changed_files [Array<String>] List of changed file paths
    # @return [Array<String>] List of re-extracted unit identifiers
    def extract_changed(changed_files)
      # Load existing graph
      graph_path = @output_dir.join("dependency_graph.json")
      if graph_path.exist?
        @dependency_graph = DependencyGraph.from_h(JSON.parse(File.read(graph_path)))
      end

      # Compute affected units
      affected_ids = @dependency_graph.affected_by(changed_files)
      Rails.logger.info "[CodebaseIndex] #{changed_files.size} changed files affect #{affected_ids.size} units"

      # Re-extract affected units
      affected_ids.each do |unit_id|
        re_extract_unit(unit_id)
      end

      # Update graph and output
      write_dependency_graph
      write_manifest

      affected_ids
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Setup
    # ──────────────────────────────────────────────────────────────────────

    def setup_output_directory
      FileUtils.mkdir_p(@output_dir)
      EXTRACTORS.keys.each do |type|
        FileUtils.mkdir_p(@output_dir.join(type.to_s))
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Dependency Resolution
    # ──────────────────────────────────────────────────────────────────────

    def resolve_dependents
      all_units = @results.values.flatten

      all_units.each do |unit|
        unit.dependencies.each do |dep|
          target_unit = find_unit(all_units, dep[:target])
          if target_unit
            target_unit.dependents ||= []
            target_unit.dependents << {
              type: unit.type,
              identifier: unit.identifier
            }
          end
        end
      end
    end

    def find_unit(units, identifier)
      units.find { |u| u.identifier == identifier }
    end

    # ──────────────────────────────────────────────────────────────────────
    # Git Enrichment
    # ──────────────────────────────────────────────────────────────────────

    def enrich_with_git_data
      return unless git_available?

      @results.each do |type, units|
        # Skip framework/gem sources - they don't live in the project repo
        next if type == :rails_source || type == :gem_source

        units.each do |unit|
          next unless unit.file_path && File.exist?(unit.file_path)

          unit.metadata[:git] = extract_git_data(unit.file_path)
        end
      end
    end

    def git_available?
      _, status = Open3.capture2("git", "rev-parse", "--git-dir")
      status.success?
    rescue StandardError
      false
    end

    # Safe git command execution — no shell interpolation
    #
    # @param args [Array<String>] Git command arguments
    # @return [String] Command output (empty string on failure)
    def run_git(*args)
      output, status = Open3.capture2("git", *args)
      status.success? ? output.strip : ""
    rescue StandardError
      ""
    end

    def extract_git_data(file_path)
      relative_path = file_path.sub(Rails.root.to_s + "/", "")

      {
        last_modified: run_git("log", "-1", "--format=%cI", "--", relative_path).presence,
        last_author: run_git("log", "-1", "--format=%an", "--", relative_path).presence,
        commit_count: run_git("rev-list", "--count", "HEAD", "--", relative_path).to_i,

        # Top contributors
        contributors: extract_contributors(relative_path),

        # Recent commits for context
        recent_commits: extract_recent_commits(relative_path),

        # Change frequency classification
        change_frequency: calculate_change_frequency(relative_path)
      }
    rescue StandardError => e
      Rails.logger.debug "[CodebaseIndex] Git data extraction failed for #{file_path}: #{e.message}"
      {}
    end

    def extract_contributors(relative_path)
      output = run_git("shortlog", "-sn", "--no-merges", "--", relative_path)
      output.lines.first(5).map do |line|
        count, name = line.strip.split("\t", 2)
        { name: name, commits: count.to_i }
      end
    rescue StandardError
      []
    end

    def extract_recent_commits(relative_path, limit: 5)
      output = run_git("log", "-#{limit}", "--format=%H|||%s|||%cI|||%an", "--", relative_path)
      output.lines.map do |line|
        sha, message, date, author = line.strip.split("|||")
        { sha: sha&.first(8), message: message, date: date, author: author }
      end
    rescue StandardError
      []
    end

    def calculate_change_frequency(relative_path)
      # Count commits in last 90 days
      recent = run_git("rev-list", "--count", "--since=90 days ago", "HEAD", "--", relative_path).to_i

      # Count total commits
      total = run_git("rev-list", "--count", "HEAD", "--", relative_path).to_i

      return :new if total <= 2
      return :hot if recent >= 10
      return :active if recent >= 3
      return :stable if recent >= 1
      :dormant
    rescue StandardError
      :unknown
    end

    # ──────────────────────────────────────────────────────────────────────
    # Output Writers
    # ──────────────────────────────────────────────────────────────────────

    def write_results
      @results.each do |type, units|
        type_dir = @output_dir.join(type.to_s)

        units.each do |unit|
          # Create safe filename from identifier
          file_name = unit.identifier.gsub("::", "__").gsub(/[^a-zA-Z0-9_-]/, "_") + ".json"

          File.write(
            type_dir.join(file_name),
            JSON.pretty_generate(unit.to_h)
          )
        end

        # Also write a type index for fast lookups
        index = units.map do |u|
          {
            identifier: u.identifier,
            file_path: u.file_path,
            namespace: u.namespace,
            estimated_tokens: u.estimated_tokens,
            chunk_count: u.chunks.size
          }
        end

        File.write(
          type_dir.join("_index.json"),
          JSON.pretty_generate(index)
        )
      end
    end

    def write_dependency_graph
      graph_data = @dependency_graph.to_h
      graph_data[:pagerank] = @dependency_graph.pagerank

      File.write(
        @output_dir.join("dependency_graph.json"),
        JSON.pretty_generate(graph_data)
      )
    end

    def write_graph_analysis
      return unless @graph_analysis

      File.write(
        @output_dir.join("graph_analysis.json"),
        JSON.pretty_generate(@graph_analysis)
      )
    end

    def write_manifest
      manifest = {
        extracted_at: Time.current.iso8601,
        rails_version: Rails.version,
        ruby_version: RUBY_VERSION,

        # Counts by type
        counts: @results.transform_values(&:size),

        # Total stats
        total_units: @results.values.sum(&:size),
        total_chunks: @results.values.flatten.sum { |u| u.chunks.size },

        # Git info
        git_sha: run_git("rev-parse", "HEAD").presence,
        git_branch: run_git("rev-parse", "--abbrev-ref", "HEAD").presence,

        # For change detection
        gemfile_lock_sha: gemfile_lock_sha,
        schema_sha: schema_sha
      }

      File.write(
        @output_dir.join("manifest.json"),
        JSON.pretty_generate(manifest)
      )
    end

    def write_structural_summary
      summary = []

      summary << "# Codebase Index Summary"
      summary << "Generated: #{Time.current.iso8601}"
      summary << "Rails #{Rails.version} / Ruby #{RUBY_VERSION}"
      summary << ""

      @results.each do |type, units|
        summary << "## #{type.to_s.titleize} (#{units.size})"
        summary << ""

        # Group by namespace
        by_namespace = units.group_by { |u| u.namespace || "(root)" }
        by_namespace.sort.each do |ns, ns_units|
          summary << "### #{ns}"
          ns_units.sort_by(&:identifier).each do |unit|
            chunks = unit.chunks.any? ? " [#{unit.chunks.size} chunks]" : ""
            summary << "- #{unit.identifier}#{chunks}"
          end
          summary << ""
        end
      end

      # Dependency summary
      summary << "## Dependency Overview"
      summary << ""

      graph_stats = @dependency_graph.to_h[:stats]
      if graph_stats
        summary << "- Total nodes: #{graph_stats[:node_count]}"
        summary << "- Total edges: #{graph_stats[:edge_count]}"
      end
      summary << ""

      File.write(
        @output_dir.join("SUMMARY.md"),
        summary.join("\n")
      )
    end

    # ──────────────────────────────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────────────────────────────

    def gemfile_lock_sha
      lock_path = Rails.root.join("Gemfile.lock")
      return nil unless lock_path.exist?
      Digest::SHA256.file(lock_path).hexdigest
    end

    def schema_sha
      schema_path = Rails.root.join("db/schema.rb")
      return nil unless schema_path.exist?
      Digest::SHA256.file(schema_path).hexdigest
    end

    def log_summary
      total = @results.values.sum(&:size)
      chunks = @results.values.flatten.sum { |u| u.chunks.size }

      Rails.logger.info "[CodebaseIndex] ═══════════════════════════════════════════"
      Rails.logger.info "[CodebaseIndex] Extraction Complete"
      Rails.logger.info "[CodebaseIndex] ═══════════════════════════════════════════"
      @results.each do |type, units|
        Rails.logger.info "[CodebaseIndex]   #{type}: #{units.size} units"
      end
      Rails.logger.info "[CodebaseIndex] ───────────────────────────────────────────"
      Rails.logger.info "[CodebaseIndex]   Total: #{total} units, #{chunks} chunks"
      Rails.logger.info "[CodebaseIndex]   Output: #{@output_dir}"
      Rails.logger.info "[CodebaseIndex] ═══════════════════════════════════════════"
    end

    # ──────────────────────────────────────────────────────────────────────
    # Incremental Re-extraction
    # ──────────────────────────────────────────────────────────────────────

    def re_extract_unit(unit_id)
      # Framework source only changes on version updates
      if unit_id.start_with?("rails/") || unit_id.start_with?("gems/")
        Rails.logger.debug "[CodebaseIndex] Skipping framework re-extraction for #{unit_id}"
        return
      end

      # Find the unit's type from the graph
      node = @dependency_graph.to_h[:nodes][unit_id]
      return unless node

      type = node[:type]&.to_sym
      file_path = node[:file_path]

      return unless file_path && File.exist?(file_path)

      # Re-extract based on type
      extractor = EXTRACTORS[type]&.new
      return unless extractor

      unit = case type
             when :model
               klass = begin
                 unit_id.constantize
               rescue StandardError
                 nil
               end
               extractor.extract_model(klass) if klass
             when :controller
               klass = begin
                 unit_id.constantize
               rescue StandardError
                 nil
               end
               extractor.extract_controller(klass) if klass
             when :service
               extractor.extract_service_file(file_path)
             when :component
               klass = begin
                 unit_id.constantize
               rescue StandardError
                 nil
               end
               extractor.extract_component(klass) if klass
             end

      if unit
        # Update dependency graph
        @dependency_graph.register(unit)

        # Write updated unit
        type_dir = @output_dir.join(type.to_s)
        file_name = unit.identifier.gsub("::", "__").gsub(/[^a-zA-Z0-9_-]/, "_") + ".json"

        File.write(
          type_dir.join(file_name),
          JSON.pretty_generate(unit.to_h)
        )

        Rails.logger.info "[CodebaseIndex] Re-extracted #{unit_id}"
      end
    end
  end
end
