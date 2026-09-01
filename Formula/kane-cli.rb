# typed: false
# frozen_string_literal: true

require "json"

class KaneCli < Formula
  desc "KaneAI browser automation CLI - AI-powered testing"
  homepage "https://www.lambdatest.com/kane-ai"
  url "https://registry.npmjs.org/@testmuai/kane-cli/-/kane-cli-0.8.8.tgz"
  sha256 "628e5f75a95d5ecfb86172d32b225516893e47b8426dc915c2096ec667905b26"
  license "Apache-2.0"
  version "0.8.8"

  bottle do
    root_url "https://github.com/LambdaTest/homebrew-kane/releases/download/kane-cli-0.8.8"
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "2fb17eecfb6fd09d21e814dca0ca5a43e33a1583df08a12ba9774199967f0d9b"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "5334f72036433999a45c518b7d473039abaaec42d7978427658e3164d26cb498"
  end

  depends_on "node"

  def install
    # Strip --build-from-source from std_npm_args (brew/Library/Homebrew/
    # language/node.rb injects it unconditionally). For sharp, that flag
    # forces a node-gyp compile instead of using the prebuilt — which
    # invokes the toolchain. Strip it so install stays toolchain-free.
    args = std_npm_args.reject { |arg| arg == "--build-from-source" }
    system "npm", "install", *args

    # Install the platform-specific optional deps that ship the binaries.
    # brew's `--prefix=#{libexec}` mode behaves like a global install and
    # modern npm skips `optionalDependencies` in that mode, so the two
    # subpackages are missing after the main install — kane-cli then can't
    # find its binaries at runtime.
    #
    # Since the node-split release the binaries live in separate packages:
    #   @testmuai/kane-cli-<plat>            -> v16-runner, versioned with
    #                                           the CLI
    #   @testmuai/kane-cli-assurance-<plat>  -> assurance-agent, versioned
    #                                           with the CLI (split out of
    #                                           the platform package when the
    #                                           combined tarball outgrew
    #                                           npm's publish size cap;
    #                                           pre-split releases ship it
    #                                           inside the platform package)
    #   @testmuai/kane-cli-node-<plat>       -> the bundled Node runtime,
    #                                           versioned by the NODE PIN
    #                                           (e.g. 24.18.0) and reused
    #                                           across CLI releases until
    #                                           the pin moves
    # Install them explicitly into the main package's nested node_modules so
    # the runtime resolver finds them via the first probed path. brew's
    # --ignore-scripts also blocks the packages' postinstall (which chmods
    # the binaries), so chmod here ourselves.
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

    node_pkg = platform_pkg.sub("kane-cli-", "kane-cli-node-")

    pkg_dir = libexec/"lib/node_modules/@testmuai/kane-cli"

    # The runtime package's version is whatever this CLI release pins in its
    # optionalDependencies — read it from the installed meta, never hardcode
    # a Node version here (the pin outlives CLI releases and moves on its
    # own cadence).
    meta = JSON.parse((pkg_dir/"package.json").read)
    node_pkg_version = meta.dig("optionalDependencies", node_pkg)
    if node_pkg_version.nil?
      odie "#{node_pkg} is not in the meta's optionalDependencies — " \
           "this formula requires a node-split kane-cli release (>= 0.6.6)."
    end

    # Layout discovery, not a version cutoff: a meta that lists the assurance
    # package in optionalDependencies is a post-split release (agent in its
    # own package); one that doesn't is pre-split (agent inside the platform
    # package). Both install correctly from this formula.
    assurance_pkg = platform_pkg.sub("kane-cli-", "kane-cli-assurance-")
    assurance_pkg_version = meta.dig("optionalDependencies", assurance_pkg)
    agent_pkg = assurance_pkg_version ? assurance_pkg : platform_pkg

    # kane-cli needs every binary across both packages: v16-runner drives the
    # browser, assurance-agent backs AI test authoring, and node is the
    # bundled runtime the CLI respawns onto (the `node` dependency above is
    # install-time only). Checking only some leaves the rest free to go
    # missing unnoticed.
    binaries = {
      "v16-runner"      => pkg_dir/"node_modules/#{platform_pkg}/bin/v16-runner",
      "assurance-agent" => pkg_dir/"node_modules/#{agent_pkg}/bin/assurance-agent",
      "node"            => pkg_dir/"node_modules/#{node_pkg}/bin/node",
    }

    install_specs = ["#{platform_pkg}@#{version}", "#{node_pkg}@#{node_pkg_version}"]
    install_specs << "#{assurance_pkg}@#{assurance_pkg_version}" if assurance_pkg_version

    # A binary counts as installed only if it exists AND is a real (multi-MB)
    # file — a present but empty/truncated one is the silent-broken-bottle mode.
    complete = lambda do
      binaries.each_value.all? { |path| path.exist? && path.size > 1_000_000 }
    end

    cd pkg_dir do
      # Retry the subpackage installs with backoff: they are published
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
                     *install_specs
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
      msg = "missing or truncated after installing #{install_specs.join(" + ")}: " \
            "#{missing.join(", ")}"
      if ENV["CI"] || ENV["HOMEBREW_BUILD_BOTTLE"]
        odie msg
      else
        opoo "#{msg}. kane-cli is installed, but the commands that need these binaries will " \
             "not work until the packages are available on npm — re-run " \
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
    node_pkg = runner_pkg.sub("kane-cli-", "kane-cli-node-")
    meta_root = libexec/"lib/node_modules/@testmuai/kane-cli"
    # Same layout discovery as def install: post-split metas list the
    # assurance package in optionalDependencies; pre-split releases carry the
    # agent inside the platform package.
    assurance_pkg = runner_pkg.sub("kane-cli-", "kane-cli-assurance-")
    meta = JSON.parse((meta_root/"package.json").read)
    agent_pkg = meta.dig("optionalDependencies", assurance_pkg) ? assurance_pkg : runner_pkg
    pkg_root = meta_root/"node_modules/#{runner_pkg}"
    agent_root = meta_root/"node_modules/#{agent_pkg}"
    node_root = meta_root/"node_modules/#{node_pkg}"
    [[pkg_root, "v16-runner"], [agent_root, "assurance-agent"], [node_root, "node"]].each do |root, name|
      binary = root/"bin"/name
      assert_path_exists binary, "#{name} binary missing — #{root.basename} not installed"
      assert_predicate binary, :executable?, "#{name} not executable — install-time chmod missed"
    end
    # The bundled runtime must be exactly the version the node package was
    # built with — read the stamp (it lives in the NODE package since the
    # split), never hardcode a Node version here.
    pin = JSON.parse((node_root/"package.json").read)["nodeRuntimeVersion"]
    refute_nil pin, "node package carries no nodeRuntimeVersion stamp"
    assert_equal "v#{pin}", shell_output("#{node_root}/bin/node --version").strip
    # And the CLI must actually RUN on it: the trampoline warns on stderr
    # whenever it falls back to system node, so a warning-free launch proves
    # the bundled respawn end-to-end (--version output itself stays bare).
    refute_match(/bundled Node runtime/, shell_output("#{bin}/kane-cli --version 2>&1"))
  end
end
