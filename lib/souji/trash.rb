# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"

module Souji
  # Cross-platform safe-delete helper. Tries platform-appropriate trash
  # commands first; falls back to FileUtils.rm_rf with an explicit stderr
  # warning so that an irreversible deletion is never silent.
  #
  # Detection order:
  # - macOS: `trash` (Homebrew), then `osascript` Finder fallback.
  # - Linux: `gio trash`.
  # - Last resort everywhere: `FileUtils.rm_rf` with stderr warning.
  module Trash
    module_function

    # Returns :trashed when the resource went to a recoverable place,
    # :deleted when we had to hard-delete (with a stderr warning),
    # or [:failed, message] if even hard-delete failed.
    def dispose(path, warn_io: $stderr)
      return [:failed, "path does not exist: #{path}"] unless File.exist?(path)

      backend = pick_backend
      return hard_delete(path, warn_io: warn_io, reason: "no trash backend available") if backend == :none

      ok = case backend
           when :trash_cli then system("trash", path, out: File::NULL, err: File::NULL)
           when :osascript then osascript_trash(path)
           when :gio_trash then system("gio", "trash", path, out: File::NULL, err: File::NULL)
           end

      return :trashed if ok

      hard_delete(path, warn_io: warn_io, reason: "trash backend #{backend} failed")
    end

    def pick_backend
      if macos?
        return :trash_cli if available?("trash")
        return :osascript if available?("osascript")
      elsif linux?
        return :gio_trash if available?("gio")
      end
      :none
    end

    def available?(cmd)
      system("command -v #{Shellwords.escape(cmd)} >/dev/null 2>&1")
    end

    def macos?
      RbConfig::CONFIG["host_os"] =~ /darwin/
    end

    def linux?
      RbConfig::CONFIG["host_os"] =~ /linux/
    end

    def osascript_trash(path)
      script = %(tell application "Finder" to delete (POSIX file #{path.inspect} as alias))
      system("osascript", "-e", script, out: File::NULL, err: File::NULL)
    end

    def hard_delete(path, warn_io:, reason:)
      warn_io.puts("[souji] WARNING: hard-deleting #{path} (#{reason}); this is irreversible")
      FileUtils.rm_rf(path)
      :deleted
    end
  end
end
