# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Souji
  module SpecSupport
    # Build a scratch directory under spec/tmp/ for the duration of an
    # example, then remove it. Returns the directory's absolute path.
    module TmpDir
      def with_tmp_dir(prefix: "souji-spec-")
        root = File.expand_path("../tmp", __dir__)
        FileUtils.mkdir_p(root)
        dir = Dir.mktmpdir(prefix, root)
        yield File.realpath(dir)
      ensure
        FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::TmpDir
end
