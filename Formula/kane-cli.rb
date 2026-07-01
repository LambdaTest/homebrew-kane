# typed: false
# frozen_string_literal: true

class KaneCli < Formula
  desc "KaneAI browser automation CLI - AI-powered testing"
  homepage "https://www.lambdatest.com/kane-ai"
  url "https://registry.npmjs.org/@testmuai/kane-cli/-/kane-cli-0.4.9.tgz"
  sha256 "7d62175fae544f911e2d7cc266fb6c2f6333e9abdb95e9d2c50df43c0ff4cdcf"
  license "Apache-2.0"
  version "0.4.9"

  bottle do
    root_url "https://github.com/LambdaTest/homebrew-kane/releases/download/kane-cli-0.4.9"
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "f1b3e8dcb6abaea016df58afc3285d251f5d26c7efea749646293c101b441eef"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "2fbd7eac16c462744fe88c4c12a364c38497c71ec86aa8b4bfdc97ae47caeb5d"
  end

  depends_on "node"

  def install
    # Strip --build-from-source from std_npm_args (brew/Library/Homebrew/
    # language/node.rb injects it unconditionally). For sharp, that flag
    # forces a node-gyp compile instead of using the prebuilt — which
    # invokes the toolchain. Strip it so install stays toolchain-free.
    args = std_npm_args.reject { |arg| arg == "--build-from-source" }
    system "npm", "install", *args

    # Install the platform-specific optional dep that ships v16-runner.
    # brew's `--prefix=#{libexec}` mode behaves like a global install and
    # modern npm skips `optionalDependencies` in that mode, so the platform
    # subpackage (@testmuai/kane-cli-<plat>) is missing after the main
    # install — kane-cli then can't find v16-runner at runtime.
    #
    # Install it explicitly into the main package's nested node_modules so
    # the runtime resolver finds it via the first probed path (`<pkg>/dist
    # /../node_modules/<plat-pkg>/bin/v16-runner`). brew's --ignore-scripts
    # also blocks the platform pkg's postinstall (which chmods the binary),
    # so chmod here ourselves.
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
    runner = pkg_dir/"node_modules/#{platform_pkg}/bin/v16-runner"
    cd pkg_dir do
      # Retry the platform install with backoff: the subpackage is published
      # separately from the main pkg and can lag behind on the npm registry,
      # so a fresh version may 404 / install nothing on the first try. Use
      # quiet_system (NOT system) so a nonzero exit doesn't raise and abort
      # before the later backoff attempts run. --prefer-online forces a real
      # re-fetch instead of replaying a stale/negative cache entry. Mirror
      # brew's tightened npm flags; we chmod the binary ourselves below.
      [0, 15, 45].each do |backoff|
        sleep backoff if backoff.positive?
        quiet_system "npm", "install", "--no-save",
                     "--ignore-scripts", "--audit=false", "--fund=false",
                     "--loglevel=error", "--prefer-online",
                     "--cache=#{HOMEBREW_CACHE}/npm_cache",
                     "#{platform_pkg}@#{version}"
        break if runner.exist? && runner.size > 1_000_000
      end
    end

    # The runner must exist AND be a real (multi-MB) binary — a present but
    # empty/truncated file is the silent-broken-bottle failure mode. On CI /
    # bottle builds, fail hard so a broken bottle can never build green. On a
    # user source-build, warn but complete (the JS CLI still works; only
    # `kane-cli run` needs the runner) rather than rolling back the install.
    if runner.exist? && runner.size > 1_000_000
      chmod 0755, runner
    else
      msg = "v16-runner missing or truncated after installing #{platform_pkg}@#{version} " \
            "(found: #{runner.exist? ? "#{runner.size} bytes" : "absent"})"
      if ENV["CI"] || ENV["HOMEBREW_BUILD_BOTTLE"]
        odie msg
      else
        opoo "#{msg}. kane-cli is installed but `kane-cli run` will not work until the " \
             "platform package is available on npm — re-run `brew reinstall kane-cli` later."
      end
    end

    bin.install_symlink libexec.glob("bin/*")
  end

  def caveats
    <<~EOS
      Currently supported platforms: macOS (Apple Silicon and Intel) and Linux x64.
      ARM Linux is not yet available.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kane-cli --version")
    # Smoke-test the v16-runner binary is present and executable. Without
    # this, `kane-cli --version` passes (it's pure JS) but `kane-cli run`
    # throws `v16-runner not found`. See git history for the regression.
    runner_pkg =
      if OS.mac?
        Hardware::CPU.arm? ? "@testmuai/kane-cli-darwin-arm64" : "@testmuai/kane-cli-darwin-x64"
      elsif OS.linux? && Hardware::CPU.intel?
        "@testmuai/kane-cli-linux-x64"
      end
    runner = libexec/"lib/node_modules/@testmuai/kane-cli/node_modules/#{runner_pkg}/bin/v16-runner"
    assert_predicate runner, :exist?, "v16-runner binary missing — platform pkg #{runner_pkg} not installed"
    assert_predicate runner, :executable?, "v16-runner not executable — postinstall chmod missed"
  end
end
