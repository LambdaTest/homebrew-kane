# typed: false
# frozen_string_literal: true

class KaneCli < Formula
  desc "KaneAI browser automation CLI - AI-powered testing"
  homepage "https://www.lambdatest.com/kane-ai"
  url "https://registry.npmjs.org/@testmuai/kane-cli/-/kane-cli-0.4.2.tgz"
  sha256 "5b1b53ce9c8389ad985486170894b270111a2100dcfff8a9cef88cb2840c60a1"
  license "Apache-2.0"
  version "0.4.2"

  bottle do
    root_url "https://github.com/LambdaTest/homebrew-kane/releases/download/kane-cli-0.4.2"
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "90b1a6422ccc56b37884fa19c3c8641fc1a2074d6ce667dc26b2a986548d72e9"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "688f49ea8f916d277e938fc00ee43e29af8e23af6b9eab44450103567d077b45"
  end

  # Bottle block intentionally removed — the previously published bottles
  # ship without the v16-runner binary (platform optional dep was missing
  # from the brew install). The `.github/workflows/build-bottles.yml`
  # pipeline rebuilds bottles and rewrites this block when re-run after
  # this fix lands. Until then brew falls back to source build, which is
  # correct with the install changes below.

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
    cd pkg_dir do
      # Mirror brew's tightened npm flags (--ignore-scripts, --audit/fund off)
      # so this second install matches the security/sandbox stance of the
      # first. We chmod the binary ourselves below, so blocking the pkg's
      # postinstall is fine.
      system "npm", "install", "--no-save",
             "--ignore-scripts", "--audit=false", "--fund=false",
             "--loglevel=error",
             "--cache=#{HOMEBREW_CACHE}/npm_cache",
             "#{platform_pkg}@#{version}"
    end
    runner = pkg_dir/"node_modules/#{platform_pkg}/bin/v16-runner"
    chmod 0755, runner if runner.exist?

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
