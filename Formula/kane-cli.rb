# typed: false
# frozen_string_literal: true

require "json"

class KaneCli < Formula
  desc "KaneAI browser automation CLI - AI-powered testing"
  homepage "https://www.lambdatest.com/kane-ai"
  url "https://registry.npmjs.org/@testmuai/kane-cli/-/kane-cli-0.6.4.tgz"
  sha256 "2f938603cf9a5455a2d3aa28ceb59f7f8f8e7e6d501056ad9a44c8a24c873d82"
  license "Apache-2.0"
  version "0.6.4"

  depends_on "node"

  def install
    # Strip --build-from-source from std_npm_args (brew/Library/Homebrew/
    # language/node.rb injects it unconditionally). For sharp, that flag
    # forces a node-gyp compile instead of using the prebuilt — which
    # invokes the toolchain. Strip it so install stays toolchain-free.
    args = std_npm_args.reject { |arg| arg == "--build-from-source" }
    system "npm", "install", *args

    # Install the platform-specific optional dep that ships the binaries.
    # brew's `--prefix=#{libexec}` mode behaves like a global install and
    # modern npm skips `optionalDependencies` in that mode, so the platform
    # subpackage (@testmuai/kane-cli-<plat>) is missing after the main
    # install — kane-cli then can't find its binaries at runtime.
    #
    # Install it explicitly into the main package's nested node_modules so
    # the runtime resolver finds them via the first probed path (`<pkg>/dist
    # /../node_modules/<plat-pkg>/bin/`). brew's --ignore-scripts also blocks
    # the platform pkg's postinstall (which chmods the binaries), so chmod
    # here ourselves.
    # Hardware::CPU.arm? is true on Linux aarch64 too — gate Linux on
    # `intel?` so we don't try to install an x64 binary on linux-arm64.
    platform_pkg =
      if OS.mac?
        Hardware::CPU.arm? ? "@testmuai/kane-cli-darwin-arm64" : "@testmuai/kane-cli-darwin-x64"
      elsif OS.linux? && Hardware::CPU.intel?
        "@testmuai/kane-cli-linux-x64"
      end

    # Match the caveats: kane-cli is unusable without v16-runner, so fail
    # loudly at install time on platforms that don't ship one rather than
    # producing a silent broken install.
    odie "kane-cli does not yet ship a v16-runner binary for this platform." if platform_pkg.nil?

    pkg_dir = libexec/"lib/node_modules/@testmuai/kane-cli"
    bin_dir = pkg_dir/"node_modules/#{platform_pkg}/bin"

    # The platform package ships three binaries and kane-cli needs them all:
    # v16-runner drives the browser, assurance-agent backs AI test authoring,
    # and node is the bundled runtime the CLI respawns onto (the `node`
    # dependency above is install-time only). Checking only some leaves the
    # rest free to go missing unnoticed.
    binaries = ["v16-runner", "assurance-agent", "node"].to_h { |name| [name, bin_dir/name] }

    # A binary counts as installed only if it exists AND is a real (multi-MB)
    # file — a present but empty/truncated one is the silent-broken-bottle mode.
    complete = lambda do
      binaries.each_value.all? { |path| path.exist? && path.size > 1_000_000 }
    end

    cd pkg_dir do
      # Retry the platform install with backoff: the subpackage is published
      # separately from the main pkg and can lag behind on the npm registry,
      # so a fresh version may 404 / install nothing on the first try. Use
      # quiet_system (NOT system) so a nonzero exit doesn't raise and abort
      # before the later backoff attempts run. --prefer-online forces a real
      # re-fetch instead of replaying a stale/negative cache entry. Mirror
      # brew's tightened npm flags; we chmod the binaries ourselves below.
      [0, 15, 45].each do |backoff|
        sleep backoff if backoff.positive?
        quiet_system "npm", "install", "--no-save",
                     "--ignore-scripts", "--audit=false", "--fund=false",
                     "--loglevel=error", "--prefer-online",
                     "--cache=#{HOMEBREW_CACHE}/npm_cache",
                     "#{platform_pkg}@#{version}"
        # Retry until EVERY binary landed — breaking as soon as one is present
        # would let a half-installed package look complete and stop retrying.
        break if complete.call
      end
    end

    # On CI / bottle builds, fail hard so a broken bottle can never build green.
    # On a user source-build, warn but complete (the JS CLI still works) rather
    # than rolling back the install.
    if complete.call
      binaries.each_value { |path| chmod 0755, path }
    else
      missing = binaries.reject { |_, path| path.exist? && path.size > 1_000_000 }
                        .map { |name, path| "#{name} (#{path.exist? ? "#{path.size} bytes" : "absent"})" }
      msg = "missing or truncated after installing #{platform_pkg}@#{version}: #{missing.join(", ")}"
      if ENV["CI"] || ENV["HOMEBREW_BUILD_BOTTLE"]
        odie msg
      else
        opoo "#{msg}. kane-cli is installed, but the commands that need these binaries will " \
             "not work until the platform package is available on npm — re-run " \
             "`brew reinstall kane-cli` later."
      end
    end

    bin.install_symlink libexec.glob("bin/*")
  end

  def caveats
    <<~EOS
      Currently supported platforms: macOS (Apple Silicon and Intel) and Linux x64.
      ARM Linux is not yet available.
      kane-cli runs on its own bundled Node runtime; the `node` dependency is
      only used at install time (npm).
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kane-cli --version")
    # Smoke-test that every bundled binary is present and executable. Without
    # this, `kane-cli --version` passes (it's pure JS) while the commands that
    # need a binary throw `not found` at the user. See git history for the
    # regression.
    runner_pkg =
      if OS.mac?
        Hardware::CPU.arm? ? "@testmuai/kane-cli-darwin-arm64" : "@testmuai/kane-cli-darwin-x64"
      elsif OS.linux? && Hardware::CPU.intel?
        "@testmuai/kane-cli-linux-x64"
      end
    pkg_root = libexec/"lib/node_modules/@testmuai/kane-cli/node_modules/#{runner_pkg}"
    ["v16-runner", "assurance-agent", "node"].each do |name|
      binary = pkg_root/"bin"/name
      assert_predicate binary, :exist?, "#{name} binary missing — platform pkg #{runner_pkg} not installed"
      assert_predicate binary, :executable?, "#{name} not executable — install-time chmod missed"
    end
    # The bundled runtime must be exactly the version the platform package was
    # built with — read the stamp, never hardcode a Node version here.
    pin = JSON.parse((pkg_root/"package.json").read)["nodeRuntimeVersion"]
    refute_nil pin, "platform package carries no nodeRuntimeVersion stamp"
    assert_equal "v#{pin}", shell_output("#{pkg_root}/bin/node --version").strip
    # And the CLI must actually RUN on it: the trampoline warns on stderr
    # whenever it falls back to system node, so a warning-free launch proves
    # the bundled respawn end-to-end (--version output itself stays bare).
    refute_match(/bundled Node runtime/, shell_output("#{bin}/kane-cli --version 2>&1"))
  end
end
