# frozen_string_literal: true

require "fileutils"
require "souji/recipes/python_venv"

RSpec.describe Souji::Recipes::PythonVenv do
  let(:recipe) { described_class.new }

  describe "class-level declarations" do
    it "registers under 'python-venv'" do
      expect(described_class.recipe_name).to eq("python-venv")
    end

    it "declares no required external commands (pure filesystem)" do
      expect(described_class.required_external_commands).to eq([])
    end

    it "declares only older_than_days" do
      expect(described_class.param_names).to eq([:older_than_days])
    end
  end

  describe "#enumerate" do
    it "proposes a venv beside a manifest that can recreate it" do
      with_tmp_dir do |tmp|
        venv = make_python_venv(File.join(tmp, "app"))

        items = recipe.enumerate([tmp], {})

        expect(items.map(&:path)).to eq([venv])
        expect(items.first.metadata).to include(
          "manifest" => "uv.lock", "manifest_kind" => "uv",
          "python_version" => "3.14.0", "created_by" => "uv 0.9.22"
        )
        expect(items.first.reason).to match(/`uv sync`/)
        expect(items.first.size_bytes).to be > 0
      end
    end

    it "detects a venv structurally, whatever it is called" do
      with_tmp_dir do |tmp|
        odd = make_python_venv(File.join(tmp, "app"), venv: "env-3.14")

        expect(recipe.enumerate([tmp], {}).map(&:path)).to eq([odd])
      end
    end

    it "leaves a tool-managed venv alone, because its parent holds no manifest" do
      with_tmp_dir do |tmp|
        # The shape direnv and Pipenv produce: the venv sits one level below
        # the project, so its immediate parent has no manifest. That venv is
        # the tool's to recreate, not ours.
        make_python_venv(File.join(tmp, "app"), venv: File.join("tool-envs", "python-3.14"))

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "does not treat a directory merely named venv as a virtualenv" do
      with_tmp_dir do |tmp|
        project = File.join(tmp, "app")
        FileUtils.mkdir_p(File.join(project, "venv", "lib"))
        File.write(File.join(project, "uv.lock"), "version = 1\n")

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "does not match a conda environment, which needs conda env remove" do
      with_tmp_dir do |tmp|
        project = File.join(tmp, "app")
        FileUtils.mkdir_p(File.join(project, "env", "conda-meta"))
        FileUtils.mkdir_p(File.join(project, "env", "bin"))
        File.write(File.join(project, "env", "bin", "python"), "")
        File.write(File.join(project, "environment.yml"), "name: fixture\n")

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a venv with no pyvenv.cfg" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"), cfg: nil)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a venv with no interpreter, which is a leftover rather than a venv" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"), interpreter: nil)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "skips a venv with no sibling manifest" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"), manifest: nil)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "does not reach past the immediate parent for a manifest" do
      with_tmp_dir do |tmp|
        # services/api/.venv with only a repository-root pyproject.toml:
        # souji must not assume the monorepo layout applies.
        repo = File.join(tmp, "monorepo")
        FileUtils.mkdir_p(repo)
        File.write(File.join(repo, "pyproject.toml"), "[project]\n")
        make_python_venv(File.join(repo, "services", "api"), manifest: nil)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "prefers a lockfile over a loose manifest" do
      with_tmp_dir do |tmp|
        project = File.join(tmp, "app")
        make_python_venv(project, manifest: "uv.lock")
        File.write(File.join(project, "pyproject.toml"), "[project]\n")
        File.write(File.join(project, "requirements.txt"), "flask\n")

        expect(recipe.enumerate([tmp], {}).first.metadata["manifest"]).to eq("uv.lock")
      end
    end

    it "accepts a loose manifest and says in the reason which kind it is" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"), manifest: "requirements.txt")

        item = recipe.enumerate([tmp], {}).first

        expect(item.metadata["manifest_kind"]).to eq("pip")
        expect(item.reason).to match(/pip install -r requirements\.txt/)
      end
    end

    it "never proposes the virtualenv souji is running inside" do
      with_tmp_dir do |tmp|
        venv = make_python_venv(File.join(tmp, "app"))

        expect(ENV).to receive(:fetch).with("VIRTUAL_ENV", nil).at_least(:once).and_return(venv)
        allow(ENV).to receive(:fetch).with("CONDA_PREFIX", nil).and_return(nil)

        expect(recipe.enumerate([tmp], {})).to eq([])
      end
    end

    it "records a broken base interpreter without letting it disqualify the venv" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"),
                         cfg: { "home" => File.join(tmp, "gone"), "version_info" => "3.14.0" })

        item = recipe.enumerate([tmp], {}).first

        expect(item.metadata["broken_interpreter"]).to be true
        expect(item.reason).to match(/base interpreter is already gone/)
      end
    end

    it "returns the same items in the same order across runs" do
      with_tmp_dir do |tmp|
        %w[b a c].each { |name| make_python_venv(File.join(tmp, name)) }

        expect(recipe.enumerate([tmp], {}).map(&:path)).to eq(recipe.enumerate([tmp], {}).map(&:path))
      end
    end

    describe "with older_than_days:" do
      it "proposes a venv whose site-packages is old enough" do
        with_tmp_dir do |tmp|
          venv = make_python_venv(File.join(tmp, "app"))
          backdate(Dir.glob(File.join(venv, "**", "*")) + [venv], days: 254)

          item = recipe.enumerate([tmp], older_than_days: 90).first

          expect(item.metadata["older_than_days"]).to eq(90)
          expect(item.reason).to match(/last install 254 days ago/)
          expect(item.metadata["install_signal"]).to eq("lib/python3.14/site-packages")
        end
      end

      it "keeps a venv that was installed into recently" do
        with_tmp_dir do |tmp|
          make_python_venv(File.join(tmp, "app"))

          expect(recipe.enumerate([tmp], older_than_days: 90)).to eq([])
        end
      end

      it "measures the install, not project source activity" do
        with_tmp_dir do |tmp|
          project = File.join(tmp, "app")
          venv = make_python_venv(project)
          backdate(Dir.glob(File.join(venv, "**", "*")) + [venv], days: 300)
          File.write(File.join(project, "main.py"), "# edited just now\n")

          expect(recipe.enumerate([tmp], older_than_days: 90).size).to eq(1)
        end
      end
    end
  end

  describe "#verify" do
    it "accepts an item whose venv is unchanged" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"))

        expect(recipe.verify(recipe.enumerate([tmp], {}).first)).to eq(:ok)
      end
    end

    it "skips a venv that is already gone" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"))
        item = recipe.enumerate([tmp], {}).first
        FileUtils.remove_entry(item.path)

        expect(recipe.verify(item)).to eq([:skip, "already removed"])
      end
    end

    it "skips once the path is no longer a virtualenv" do
      with_tmp_dir do |tmp|
        item = recipe.enumerate([tmp], {}).then do
          make_python_venv(File.join(tmp, "app"))
          recipe.enumerate([tmp], {}).first
        end
        FileUtils.rm_f(File.join(item.path, "pyvenv.cfg"))

        expect(recipe.verify(item).last).to match(/not a virtualenv/)
      end
    end

    it "skips once the manifest that would recreate it is gone" do
      with_tmp_dir do |tmp|
        project = File.join(tmp, "app")
        make_python_venv(project)
        item = recipe.enumerate([tmp], {}).first
        FileUtils.rm_f(File.join(project, "uv.lock"))

        expect(recipe.verify(item).last).to match(/no sibling manifest/)
      end
    end

    it "skips when packages were installed between plan and apply" do
      with_tmp_dir do |tmp|
        venv = make_python_venv(File.join(tmp, "app"))
        backdate(Dir.glob(File.join(venv, "**", "*")) + [venv], days: 254)
        item = recipe.enumerate([tmp], older_than_days: 90).first

        now = Time.now
        File.utime(now, now, File.join(venv, "lib", "python3.14", "site-packages"))

        expect(recipe.verify(item).last).to match(/packages installed 0 days ago/)
      end
    end
  end

  describe "#delete" do
    it "disposes of the venv and reports the outcome" do
      with_tmp_dir do |tmp|
        make_python_venv(File.join(tmp, "app"))
        item = recipe.enumerate([tmp], {}).first

        expect(%i[trashed deleted]).to include(recipe.delete(item))
      end
    end
  end
end
