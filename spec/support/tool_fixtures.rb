# frozen_string_literal: true

module Souji
  module SpecSupport
    # Real output, captured verbatim from a workstation running Rancher
    # Desktop, Homebrew, mise, uv, pnpm and go.
    #
    # Handwritten fixtures would have hidden every trap that actually
    # matters here: docker's `kB` versus Homebrew's `KB`, the thousands
    # separator in `1,707 files`, the `(virtual ...)` suffix on a container
    # size, mise's WARN lines going to stderr, and `docker buildx du`
    # reporting a "Reclaimable" that is 4.9 GB larger than what a plain
    # prune frees.
    # Constants hold the captured bytes; the snake_case readers exist
    # because constant lookup inside an RSpec example block is lexical and
    # would not find them through `include`.
    module ToolFixtures
      UV_CACHE_DIR = "/Users/u/.cache/uv\n"
      UV_CACHE_SIZE = "10007912448\n"
      UV_CACHE_SIZE_STDERR =
        "warning: `uv cache size` is experimental and may change without warning.\n"

      PNPM_STORE_PATH = "/Users/u/Library/pnpm/store/v10\n"

      GO_ENV = "/Users/u/Library/Caches/go-build\n/Users/u/go/pkg/mod\n"

      # `Would remove:` lines and the total are on stdout; the
      # `Warning: Skipping ...` noise is on stderr.
      BREW_CLEANUP_DRY_RUN = <<~OUT
        Would remove: /Users/u/Library/Caches/Homebrew/gh_bottle_manifest--2.97.0 (14.6KB)
        Would remove: /Users/u/Library/Caches/Homebrew/gh--2.97.0 (13.6MB)
        Would remove: /Users/u/Library/Caches/Homebrew/descriptions.json (498.8KB)
        Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.4 (1,707 files, 34.6MB)
        Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.5_1 (1,707 files, 34.6MB)
        ==> This operation would free approximately 667.3MB of disk space.
      OUT

      BREW_CLEANUP_DRY_RUN_STDERR = <<~ERR
        Warning: Skipping abseil: most recent version 20260817.0 not installed
        Warning: Skipping actionlint: most recent version 1.7.12 not installed
      ERR

      BREW_CLEANUP_NOTHING_TO_DO = "==> This operation would free approximately 0B of disk space.\n"

      BREW_CACHE_DIR = "/Users/u/Library/Caches/Homebrew\n"

      # A tool name can contain a colon and a slash -- `aqua:...` here --
      # which is exactly the shape a naive `tool@version` parser breaks on.
      MISE_LS_PRUNABLE_JSON = <<~JSON
        {
          "aqua:open-policy-agent/opa": [
            {
              "version": "1.13.2",
              "install_path": "/Users/u/.local/share/mise/installs/aqua-open-policy-agent-opa/1.13.2",
              "installed": true,
              "active": false
            }
          ],
          "awscli": [
            {
              "version": "2.35.12",
              "install_path": "/Users/u/.local/share/mise/installs/awscli/2.35.12",
              "installed": true,
              "active": false
            },
            {
              "version": "2.30.0",
              "install_path": "/Users/u/.local/share/mise/installs/awscli/2.30.0",
              "installed": true,
              "active": false
            }
          ],
          "node": [
            {
              "version": "22.0.0",
              "install_path": "/Users/u/.local/share/mise/installs/node/22.0.0",
              "installed": false,
              "active": false
            }
          ]
        }
      JSON

      MISE_LS_PRUNABLE_STDERR = <<~ERR
        mise WARN  no version set for python, using 3.13.12
        mise WARN  tool not installed: ruby@4.0.6
      ERR

      MISE_LS_PRUNABLE_EMPTY = "{}\n"

      DOCKER_SYSTEM_DF_JSON = <<~JSON
        {"Active":"11","Reclaimable":"6.024GB (43%)","Size":"13.7GB","TotalCount":"42","Type":"Images"}
        {"Active":"23","Reclaimable":"64.75MB (99%)","Size":"64.75MB","TotalCount":"39","Type":"Containers"}
        {"Active":"21","Reclaimable":"1.288GB (48%)","Size":"2.668GB","TotalCount":"52","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"8.709GB","Size":"13.59GB","TotalCount":"232","Type":"Build Cache"}
      JSON

      DOCKER_SYSTEM_DF_NO_BUILD_CACHE = <<~JSON
        {"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
      JSON

      # Two stopped containers. Note Size: the leading figure is the
      # writable layer `docker rm` frees; `virtual` is shared with the
      # image and is not freed.
      DOCKER_PS_TERMINAL_JSON = <<~JSON
        {"CreatedAt":"2026-09-17 17:09:00 +0900 JST","ID":"e7cb888080ea867a13068f2f2ee73cc25b3690f46ef9f9193c15d8c7e0aaed0a","Image":"postgres:16","Names":"dsql-support-pg16-1","Size":"0B (virtual 474MB)","State":"created","Status":"Created"}
        {"CreatedAt":"2026-03-02 11:20:41 +0900 JST","ID":"aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899","Image":"redis:7","Names":"old-redis","Size":"625kB (virtual 45.7MB)","State":"exited","Status":"Exited (0) 6 months ago"}
      JSON

      # What a docker version with looser filter semantics could hand back.
      # The Ruby-side re-filter is what keeps it out of a plan.
      DOCKER_PS_WITH_RUNNING_JSON = <<~JSON
        {"CreatedAt":"2026-09-17 17:09:00 +0900 JST","ID":"1111111111111111111111111111111111111111111111111111111111111111","Image":"postgres:16","Names":"live-pg","Size":"1.2MB (virtual 474MB)","State":"running","Status":"Up 19 hours"}
        {"CreatedAt":"2026-03-02 11:20:41 +0900 JST","ID":"2222222222222222222222222222222222222222222222222222222222222222","Image":"redis:7","Names":"old-redis","Size":"625kB (virtual 45.7MB)","State":"exited","Status":"Exited (0) 6 months ago"}
      JSON

      DOCKER_INFO_VM_JSON =
        %({"OSType":"linux","OperatingSystem":"Alpine Linux v3.23","Name":"lima-rancher-desktop"}\n)
      DOCKER_INFO_NATIVE_JSON =
        %({"OSType":"linux","OperatingSystem":"Ubuntu 24.04.1 LTS","Name":"build-box"}\n)

      DOCKER_IMAGE_LS_DANGLING_JSON = <<~JSON
        {"ID":"sha256:aaaa","Size":"479MB","CreatedAt":"2026-03-01 10:00:00 +0900 JST"}
        {"ID":"sha256:bbbb","Size":"1.2GB","CreatedAt":"2026-09-01 10:00:00 +0900 JST"}
      JSON

      def uv_cache_dir
        UV_CACHE_DIR
      end

      def uv_cache_size
        UV_CACHE_SIZE
      end

      def uv_cache_size_stderr
        UV_CACHE_SIZE_STDERR
      end

      def pnpm_store_path
        PNPM_STORE_PATH
      end

      def go_env
        GO_ENV
      end

      def brew_cleanup_dry_run
        BREW_CLEANUP_DRY_RUN
      end

      def brew_cleanup_dry_run_stderr
        BREW_CLEANUP_DRY_RUN_STDERR
      end

      def brew_cleanup_nothing_to_do
        BREW_CLEANUP_NOTHING_TO_DO
      end

      def brew_cache_dir
        BREW_CACHE_DIR
      end

      def mise_ls_prunable_json
        MISE_LS_PRUNABLE_JSON
      end

      def mise_ls_prunable_stderr
        MISE_LS_PRUNABLE_STDERR
      end

      def mise_ls_prunable_empty
        MISE_LS_PRUNABLE_EMPTY
      end

      def docker_system_df_json
        DOCKER_SYSTEM_DF_JSON
      end

      def docker_system_df_no_build_cache
        DOCKER_SYSTEM_DF_NO_BUILD_CACHE
      end

      def docker_ps_terminal_json
        DOCKER_PS_TERMINAL_JSON
      end

      def docker_ps_with_running_json
        DOCKER_PS_WITH_RUNNING_JSON
      end

      def docker_info_vm_json
        DOCKER_INFO_VM_JSON
      end

      def docker_info_native_json
        DOCKER_INFO_NATIVE_JSON
      end

      def docker_image_ls_dangling_json
        DOCKER_IMAGE_LS_DANGLING_JSON
      end
    end
  end
end

RSpec.configure do |config|
  config.include Souji::SpecSupport::ToolFixtures
end
