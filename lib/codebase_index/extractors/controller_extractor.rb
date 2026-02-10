# frozen_string_literal: true

require "digest"

module CodebaseIndex
  module Extractors
    # ControllerExtractor handles ActionController extraction with:
    # - Route mapping (which HTTP endpoints hit which actions)
    # - Before/after action filter chain resolution
    # - Per-action chunking for precise retrieval
    # - Concern inlining
    #
    # Controllers are chunked more aggressively than models because
    # queries are often action-specific ("how does the create action work").
    #
    # @example
    #   extractor = ControllerExtractor.new
    #   units = extractor.extract_all
    #   registrations = units.find { |u| u.identifier == "Users::RegistrationsController" }
    #
    class ControllerExtractor
      def initialize
        @routes_map = build_routes_map
      end

      # Extract all controllers in the application
      #
      # @return [Array<ExtractedUnit>] List of controller units
      def extract_all
        controllers = ApplicationController.descendants

        if defined?(ActionController::API)
          controllers = (controllers + ActionController::API.descendants).uniq
        end

        controllers.map do |controller|
          extract_controller(controller)
        end.compact
      end

      # Extract a single controller
      #
      # @param controller [Class] The controller class
      # @return [ExtractedUnit] The extracted unit
      def extract_controller(controller)
        unit = ExtractedUnit.new(
          type: :controller,
          identifier: controller.name,
          file_path: source_file_for(controller)
        )

        unit.namespace = extract_namespace(controller)
        unit.source_code = build_composite_source(controller)
        unit.metadata = extract_metadata(controller)
        unit.dependencies = extract_dependencies(controller)

        # Controllers benefit from per-action chunks
        unit.chunks = build_action_chunks(controller, unit)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract controller #{controller.name}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Route Mapping
      # ──────────────────────────────────────────────────────────────────────

      # Build a map of controller -> action -> route info from Rails routes
      def build_routes_map
        routes = {}

        Rails.application.routes.routes.each do |route|
          next unless route.defaults[:controller]

          controller = "#{route.defaults[:controller].camelize}Controller"
          action = route.defaults[:action]

          routes[controller] ||= {}
          routes[controller][action] ||= []
          routes[controller][action] << {
            verb: extract_verb(route),
            path: route.path.spec.to_s.gsub("(.:format)", ""),
            name: route.name,
            constraints: route.constraints.except(:request_method)
          }
        end

        routes
      end

      def extract_verb(route)
        verb = route.verb
        return verb if verb.is_a?(String)
        return verb.source.gsub(/[\^\$]/, "") if verb.respond_to?(:source)
        verb.to_s
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Building
      # ──────────────────────────────────────────────────────────────────────

      def source_file_for(controller)
        # Try to get from method source location
        if controller.instance_methods(false).any?
          method = controller.instance_methods(false).first
          controller.instance_method(method).source_location&.first
        end || Rails.root.join("app/controllers/#{controller.name.underscore}.rb").to_s
      rescue StandardError
        Rails.root.join("app/controllers/#{controller.name.underscore}.rb").to_s
      end

      def extract_namespace(controller)
        parts = controller.name.split("::")
        parts.size > 1 ? parts[0..-2].join("::") : nil
      end

      # Build composite source with routes and filters as headers
      def build_composite_source(controller)
        source_path = source_file_for(controller)
        return "" unless source_path && File.exist?(source_path)

        source = File.read(source_path)

        # Prepend route information
        routes_comment = build_routes_comment(controller)

        # Prepend before_action chain
        filters_comment = build_filters_comment(controller)

        "#{routes_comment}\n#{filters_comment}\n#{source}"
      end

      def build_routes_comment(controller)
        routes = @routes_map[controller.name] || {}
        return "" if routes.empty?

        lines = routes.flat_map do |action, route_list|
          route_list.map do |info|
            verb = info[:verb].to_s.ljust(7)
            path = info[:path].ljust(45)
            "  #{verb} #{path} → ##{action}"
          end
        end

        <<~ROUTES
        # ╔═══════════════════════════════════════════════════════════════════════╗
        # ║ Routes                                                                 ║
        # ╚═══════════════════════════════════════════════════════════════════════╝
        #
        #{lines.map { |l| "# #{l}" }.join("\n")}
        #
        ROUTES
      end

      def build_filters_comment(controller)
        filters = extract_filter_chain(controller)
        return "" if filters.empty?

        lines = filters.map do |f|
          opts = []
          opts << "only: [#{f[:only].map { |a| ":#{a}" }.join(', ')}]" if f[:only]&.any?
          opts << "except: [#{f[:except].map { |a| ":#{a}" }.join(', ')}]" if f[:except]&.any?
          opts << "if: #{f[:if]}" if f[:if]

          opts_str = opts.any? ? " (#{opts.join('; ')})" : ""
          "  #{f[:kind].to_s.ljust(8)} :#{f[:filter]}#{opts_str}"
        end

        <<~FILTERS
        # ╔═══════════════════════════════════════════════════════════════════════╗
        # ║ Filter Chain                                                           ║
        # ╚═══════════════════════════════════════════════════════════════════════╝
        #
        #{lines.map { |l| "# #{l}" }.join("\n")}
        #
        FILTERS
      end

      def extract_filter_chain(controller)
        controller._process_action_callbacks.map do |callback|
          {
            kind: callback.kind,
            filter: callback.filter,
            only: Array(callback.options[:only]),
            except: Array(callback.options[:except]),
            if: callback.options[:if],
            unless: callback.options[:unless]
          }
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract comprehensive metadata
      def extract_metadata(controller)
        actions = controller.action_methods.to_a

        {
          # Actions and routes
          actions: actions,
          routes: @routes_map[controller.name] || {},

          # Filter chain
          filters: extract_filter_chain(controller),

          # Parent chain for understanding inherited behavior
          ancestors: controller.ancestors
                              .take_while { |a| a != ActionController::Base && a != ActionController::API }
                              .select { |a| a.is_a?(Class) }
                              .map(&:name)
                              .compact,

          # Concerns included
          included_concerns: extract_included_concerns(controller),

          # Response formats
          responds_to: extract_respond_formats(controller),

          # Metrics
          action_count: actions.size,
          filter_count: controller._process_action_callbacks.size,

          # Strong parameters if definable
          permitted_params: extract_permitted_params(controller)
        }
      end

      def extract_included_concerns(controller)
        controller.included_modules
                  .select { |m| m.name&.include?("Concern") || m.name&.include?("Concerns") }
                  .map(&:name)
      end

      def extract_respond_formats(controller)
        source_path = source_file_for(controller)
        return [] unless source_path && File.exist?(source_path)

        source = File.read(source_path)
        formats = []

        formats << :html if source.include?("respond_to do") || !source.include?("respond_to")
        formats << :json if source.include?(":json") || source.include?("render json:")
        formats << :xml if source.include?(":xml") || source.include?("render xml:")
        formats << :turbo_stream if source.include?("turbo_stream")

        formats.uniq
      end

      def extract_permitted_params(controller)
        source_path = source_file_for(controller)
        return {} unless source_path && File.exist?(source_path)

        source = File.read(source_path)
        params = {}

        # Match params.require(:x).permit(...) patterns
        source.scan(/def\s+(\w+_params).*?params\.require\(:(\w+)\)\.permit\((.*?)\)/m) do |method, model, permitted|
          params[method] = {
            model: model,
            permitted: permitted.scan(/:(\w+)/).flatten
          }
        end

        params
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      def extract_dependencies(controller)
        deps = []
        source_path = source_file_for(controller)

        if source_path && File.exist?(source_path)
          source = File.read(source_path)

          # Model references
          ActiveRecord::Base.descendants.each do |model|
            next unless model.name
            if source.match?(/\b#{model.name}\b/)
              deps << { type: :model, target: model.name }
            end
          end

          # Service references
          source.scan(/(\w+Service)(?:\.|::new)/).flatten.uniq.each do |service|
            deps << { type: :service, target: service }
          end

          # Phlex component references
          source.scan(/render\s+(\w+(?:::\w+)*Component)/).flatten.uniq.each do |component|
            deps << { type: :component, target: component }
          end

          # Other view renders
          source.scan(/render\s+["'](\w+\/\w+)["']/).flatten.uniq.each do |template|
            deps << { type: :view, target: template }
          end

          # Mailers
          source.scan(/(\w+Mailer)\./).flatten.uniq.each do |mailer|
            deps << { type: :mailer, target: mailer }
          end

          # Jobs
          source.scan(/(\w+Job)\.perform/).flatten.uniq.each do |job|
            deps << { type: :job, target: job }
          end
        end

        deps.uniq { |d| [d[:type], d[:target]] }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Per-Action Chunking
      # ──────────────────────────────────────────────────────────────────────

      # Build per-action chunks for precise retrieval
      def build_action_chunks(controller, unit)
        controller.action_methods.filter_map do |action|
          route_info = @routes_map.dig(controller.name, action.to_s)
          filters = applicable_filters(controller, action)

          # Extract just this action's source
          action_source = extract_action_source(controller, action)
          next if action_source.nil? || action_source.strip.empty?

          route_desc = if route_info&.any?
            route_info.map { |r| "#{r[:verb]} #{r[:path]}" }.join(", ")
          else
            "No direct route"
          end

          chunk_content = <<~ACTION
          # Controller: #{controller.name}
          # Action: #{action}
          # Route: #{route_desc}
          # Filters: #{filters.map { |f| "#{f[:kind]}(:#{f[:filter]})" }.join(", ").presence || "none"}

          #{action_source}
          ACTION

          {
            chunk_type: :action,
            identifier: "#{controller.name}##{action}",
            content: chunk_content,
            content_hash: Digest::SHA256.hexdigest(chunk_content),
            metadata: {
              parent: unit.identifier,
              action: action.to_s,
              route: route_info,
              filters: filters,
              http_methods: route_info&.map { |r| r[:verb] }&.uniq || []
            }
          }
        end
      end

      def applicable_filters(controller, action)
        action_sym = action.to_sym

        controller._process_action_callbacks.select do |cb|
          applies = true
          applies = false if cb.options[:only]&.any? && !cb.options[:only].include?(action_sym)
          applies = false if cb.options[:except]&.include?(action_sym)
          applies
        end.map do |cb|
          { kind: cb.kind, filter: cb.filter }
        end
      end

      def extract_action_source(controller, action)
        method = controller.instance_method(action)
        source_location = method.source_location
        return nil unless source_location

        file, line = source_location
        return nil unless File.exist?(file)

        lines = File.readlines(file)

        # Find method boundaries
        start_line = line - 1
        return nil if start_line < 0 || start_line >= lines.length

        # Determine indentation of def line
        def_line = lines[start_line]
        indent = def_line[/^\s*/].length

        # Find end of method
        end_line = start_line + 1
        while end_line < lines.length
          current_line = lines[end_line]
          current_indent = current_line[/^\s*/]&.length || 0

          # Empty lines or lines with deeper indent continue the method
          if current_line.strip.empty?
            end_line += 1
            next
          end

          # Line at same or lesser indent that isn't a continuation
          if current_indent <= indent && current_line.strip != ""
            break
          end

          end_line += 1
        end

        lines[start_line...end_line].join
      rescue StandardError => e
        Rails.logger.debug("Could not extract action source for #{controller}##{action}: #{e.message}")
        nil
      end
    end
  end
end
