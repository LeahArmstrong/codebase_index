# frozen_string_literal: true

require "spec_helper"
require "pathname"
require "tmpdir"
require "fileutils"
require "codebase_index/extractor"

RSpec.describe CodebaseIndex::Extractor do
  # Use a real tmpdir so Pathname#exist? works without stubs.
  let(:tmpdir) { Dir.mktmpdir("codebase_index_test") }
  let(:rails_root) { Pathname.new(tmpdir) }

  before do
    stub_const("Rails", double("Rails"))
    allow(Rails).to receive(:root).and_return(rails_root)
    allow(Rails).to receive(:logger).and_return(double("Logger").as_null_object)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  let(:extractor) { described_class.new(output_dir: File.join(tmpdir, "output")) }

  # ── safe_eager_load! ────────────────────────────────────────────────

  describe "#safe_eager_load!" do
    let(:app_double) { double("Application") }

    before do
      allow(Rails).to receive(:application).and_return(app_double)
    end

    it "calls eager_load! successfully when no error" do
      expect(app_double).to receive(:eager_load!).once
      expect(extractor).not_to receive(:eager_load_extraction_directories)

      extractor.send(:safe_eager_load!)
    end

    it "falls back to per-directory loading on NameError" do
      expect(app_double).to receive(:eager_load!).and_raise(NameError.new("uninitialized constant GraphQL"))
      expect(extractor).to receive(:eager_load_extraction_directories)

      extractor.send(:safe_eager_load!)
    end

    it "does not catch non-NameError exceptions" do
      expect(app_double).to receive(:eager_load!).and_raise(RuntimeError.new("something else"))

      expect { extractor.send(:safe_eager_load!) }.to raise_error(RuntimeError, "something else")
    end
  end

  # ── eager_load_extraction_directories ────────────────────────────────

  describe "#eager_load_extraction_directories" do
    let(:loader) { double("Zeitwerk::Loader") }
    let(:autoloaders) { double("Autoloaders", main: loader) }

    before do
      allow(Rails).to receive(:autoloaders).and_return(autoloaders)
    end

    context "with Zeitwerk 2.6+ (eager_load_dir available)" do
      before do
        allow(loader).to receive(:respond_to?).with(:eager_load_dir).and_return(true)
      end

      it "calls eager_load_dir for existing directories" do
        # Create real directories
        FileUtils.mkdir_p(File.join(tmpdir, "app", "models"))
        FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers"))

        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, "app", "models"))
        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, "app", "controllers"))

        extractor.send(:eager_load_extraction_directories)
      end

      it "skips non-existent directories" do
        # Only create models, not controllers
        FileUtils.mkdir_p(File.join(tmpdir, "app", "models"))

        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, "app", "models"))
        # controllers dir doesn't exist, so no call expected

        extractor.send(:eager_load_extraction_directories)
      end

      it "rescues NameError from individual directories and continues" do
        FileUtils.mkdir_p(File.join(tmpdir, "app", "models"))
        FileUtils.mkdir_p(File.join(tmpdir, "app", "controllers"))

        allow(loader).to receive(:eager_load_dir).with(File.join(tmpdir, "app", "models"))
          .and_raise(NameError.new("bad constant"))
        expect(loader).to receive(:eager_load_dir).with(File.join(tmpdir, "app", "controllers"))

        # Should not raise — error in models/ doesn't block controllers/
        expect { extractor.send(:eager_load_extraction_directories) }.not_to raise_error
      end
    end

    context "with Zeitwerk 2.5 (no eager_load_dir)" do
      before do
        allow(loader).to receive(:respond_to?).with(:eager_load_dir).and_return(false)
      end

      it "falls back to Dir.glob + require for existing directories" do
        models_dir = File.join(tmpdir, "app", "models")
        FileUtils.mkdir_p(models_dir)
        File.write(File.join(models_dir, "user.rb"), "# user")
        File.write(File.join(models_dir, "post.rb"), "# post")

        expect(extractor).to receive(:require).with(File.join(models_dir, "post.rb")).ordered
        expect(extractor).to receive(:require).with(File.join(models_dir, "user.rb")).ordered

        extractor.send(:eager_load_extraction_directories)
      end

      it "rescues NameError from individual files and continues" do
        models_dir = File.join(tmpdir, "app", "models")
        FileUtils.mkdir_p(models_dir)
        File.write(File.join(models_dir, "bad.rb"), "# bad")
        File.write(File.join(models_dir, "good.rb"), "# good")

        allow(extractor).to receive(:require).with(File.join(models_dir, "bad.rb"))
          .and_raise(NameError.new("uninitialized constant"))
        expect(extractor).to receive(:require).with(File.join(models_dir, "good.rb"))

        expect { extractor.send(:eager_load_extraction_directories) }.not_to raise_error
      end
    end
  end

  # ── EXTRACTION_DIRECTORIES constant ──────────────────────────────────

  describe "EXTRACTION_DIRECTORIES" do
    it "is a frozen array" do
      expect(CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES).to be_frozen
    end

    it "includes core extraction targets" do
      dirs = CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES
      expect(dirs).to include("models", "controllers", "services", "jobs", "mailers")
    end

    it "does not include graphql (handled separately)" do
      expect(CodebaseIndex::Extractor::EXTRACTION_DIRECTORIES).not_to include("graphql")
    end
  end
end
