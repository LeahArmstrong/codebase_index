# frozen_string_literal: true

module CodebaseIndex
  # Railtie integrates CodebaseIndex into Rails applications.
  # Loads rake tasks automatically when the gem is bundled.
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/codebase_index.rake', __dir__)
    end
  end
end
