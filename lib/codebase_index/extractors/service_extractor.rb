# frozen_string_literal: true

module CodebaseIndex
  module Extractors
    # ServiceExtractor handles service object extraction.
    #
    # Service objects often contain the most important business logic.
    # Unlike models (which are discovered via ActiveRecord), services
    # are discovered by scanning conventional directories.
    #
    # We extract:
    # - Public interface (call/perform/execute methods)
    # - Dependencies (what models/services/jobs they use)
    # - Error classes (custom exceptions defined)
    # - Input/output patterns
    #
    # @example
    #   extractor = ServiceExtractor.new
    #   units = extractor.extract_all
    #   checkout = units.find { |u| u.identifier == "CheckoutService" }
    #
    class ServiceExtractor
      # Directories to scan for service objects
      SERVICE_DIRECTORIES = %w[
        app/services
        app/interactors
        app/operations
        app/commands
        app/use_cases
      ].freeze

      def initialize
        @directories = SERVICE_DIRECTORIES.map { |d| Rails.root.join(d) }
                                          .select { |d| d.directory? }
      end

      # Extract all service objects
      #
      # @return [Array<ExtractedUnit>] List of service units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join("**/*.rb")].filter_map do |file|
            extract_service_file(file)
          end
        end
      end

      # Extract a single service file
      #
      # @param file_path [String] Path to the service file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a service
      def extract_service_file(file_path)
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil if skip_file?(source)

        unit = ExtractedUnit.new(
          type: :service,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name)
        unit.metadata = extract_metadata(source, class_name, file_path)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract service #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Class Discovery
      # ──────────────────────────────────────────────────────────────────────

      def extract_class_name(file_path, source)
        # Try to extract from source first (handles nested modules)
        if source =~ /^\s*class\s+([\w:]+)/
          return $1
        end

        # Fall back to convention
        relative_path = file_path.sub(Rails.root.to_s + "/", "")

        # app/services/payments/stripe_service.rb -> Payments::StripeService
        relative_path
          .sub(%r{^app/(services|interactors|operations|commands|use_cases)/}, "")
          .sub(".rb", "")
          .camelize
      end

      def skip_file?(source)
        # Skip module-only files (concerns, base modules)
        source.match?(/^\s*module\s+\w+\s*$/) && !source.match?(/^\s*class\s+/)
      end

      def extract_namespace(class_name)
        parts = class_name.split("::")
        parts.size > 1 ? parts[0..-2].join("::") : nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Add annotations to help with retrieval
      def annotate_source(source, class_name)
        entry_points = detect_entry_points(source)

        annotation = <<~ANNOTATION
        # ╔═══════════════════════════════════════════════════════════════════════╗
        # ║ Service: #{class_name.ljust(60)}║
        # ║ Entry Points: #{entry_points.join(', ').ljust(55)}║
        # ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      def detect_entry_points(source)
        points = []
        points << "call" if source.match?(/def (self\.)?call\b/)
        points << "perform" if source.match?(/def (self\.)?perform\b/)
        points << "execute" if source.match?(/def (self\.)?execute\b/)
        points << "run" if source.match?(/def (self\.)?run\b/)
        points << "process" if source.match?(/def (self\.)?process\b/)
        points.empty? ? ["unknown"] : points
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_metadata(source, class_name, file_path)
        {
          # Entry points
          public_methods: extract_public_methods(source),
          entry_points: detect_entry_points(source),
          class_methods: extract_class_methods(source),

          # Patterns
          is_callable: source.match?(/def (self\.)?call\b/),
          is_interactor: source.match?(/include\s+Interactor/),
          uses_dry_monads: source.match?(/include\s+Dry::Monads/),

          # Dependency injection
          initialize_params: extract_initialize_params(source),
          injected_dependencies: extract_injected_deps(source),

          # Error handling
          custom_errors: extract_custom_errors(source),
          rescues: extract_rescue_handlers(source),

          # Return patterns
          return_type: infer_return_type(source),

          # Metrics
          loc: source.lines.count { |l| l.strip.present? && !l.strip.start_with?("#") },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size,
          complexity: estimate_complexity(source),

          # Directory context (what kind of service pattern)
          service_type: infer_service_type(file_path)
        }
      end

      def extract_public_methods(source)
        methods = []
        in_private = false
        in_protected = false

        source.each_line do |line|
          stripped = line.strip

          in_private = true if stripped == "private"
          in_protected = true if stripped == "protected"
          in_private = false if stripped == "public"
          in_protected = false if stripped == "public"

          if !in_private && !in_protected && stripped =~ /def\s+((?:self\.)?\w+[?!=]?)/
            method_name = $1
            methods << method_name unless method_name.start_with?("_")
          end
        end

        methods
      end

      def extract_class_methods(source)
        source.scan(/def\s+self\.(\w+[?!=]?)/).flatten
      end

      def extract_initialize_params(source)
        init_match = source.match(/def\s+initialize\s*\((.*?)\)/m)
        return [] unless init_match

        params_str = init_match[1]
        params = []

        # Parse parameter list
        params_str.scan(/(\w+)(?::\s*([^,\n]+))?/) do |name, default|
          params << {
            name: name,
            has_default: !default.nil?,
            keyword: params_str.include?("#{name}:")
          }
        end

        params
      end

      def extract_injected_deps(source)
        # Look for attr_reader/accessor that match common dependency patterns
        deps = []

        source.scan(/attr_(?:reader|accessor)\s+(.+)/) do |match|
          match[0].scan(/:(\w+)/).flatten.each do |attr|
            if attr.match?(/service|repository|client|adapter|gateway|notifier|mailer/)
              deps << attr
            end
          end
        end

        # Also look for initialize assignments
        source.scan(/@(\w+)\s*=\s*(\w+)/) do |ivar, value|
          if value.match?(/Service|Client|Repository|Adapter|Gateway/)
            deps << ivar
          end
        end

        deps.uniq
      end

      def extract_custom_errors(source)
        source.scan(/class\s+(\w+(?:Error|Exception))\s*</).flatten
      end

      def extract_rescue_handlers(source)
        source.scan(/rescue\s+([\w:]+)/).flatten.uniq
      end

      def infer_return_type(source)
        return :dry_monad if source.match?(/Success\(|Failure\(/)
        return :result_object if source.match?(/Result\.new|OpenStruct\.new/)
        return :boolean if source.match?(/def call.*?(?:true|false)\s*$/m)
        :unknown
      end

      def estimate_complexity(source)
        # Simple cyclomatic complexity estimate
        branches = source.scan(/\b(?:if|unless|elsif|when|while|until|for|rescue|&&|\|\|)\b/).size
        branches + 1
      end

      def infer_service_type(file_path)
        case file_path
        when /interactors/ then :interactor
        when /operations/ then :operation
        when /commands/ then :command
        when /use_cases/ then :use_case
        else :service
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(source)
        deps = []

        # Model references
        if defined?(ActiveRecord::Base)
          ActiveRecord::Base.descendants.each do |model|
            next unless model.name
            if source.match?(/\b#{model.name}\b/)
              deps << { type: :model, target: model.name }
            end
          end
        end

        # Other services
        source.scan(/(\w+Service)(?:\.|::new|\.call|\.perform)/).flatten.uniq.each do |service|
          deps << { type: :service, target: service }
        end

        # Interactors
        source.scan(/(\w+Interactor)(?:\.|::)/).flatten.uniq.each do |interactor|
          deps << { type: :interactor, target: interactor }
        end

        # Jobs
        source.scan(/(\w+Job)\.perform/).flatten.uniq.each do |job|
          deps << { type: :job, target: job }
        end

        # Mailers
        source.scan(/(\w+Mailer)\./).flatten.uniq.each do |mailer|
          deps << { type: :mailer, target: mailer }
        end

        # External API clients
        source.scan(/(\w+Client)(?:\.|::new)/).flatten.uniq.each do |client|
          deps << { type: :api_client, target: client }
        end

        # HTTP calls
        if source.match?(/HTTParty|Faraday|RestClient|Net::HTTP/)
          deps << { type: :external, target: :http_api }
        end

        # Redis
        if source.match?(/Redis\.current|REDIS|Sidekiq\.redis/)
          deps << { type: :infrastructure, target: :redis }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
