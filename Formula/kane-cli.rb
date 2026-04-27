# typed: false
# frozen_string_literal: true

class KaneCli < Formula
  desc "KaneAI browser automation CLI - AI-powered testing"
  homepage "https://www.lambdatest.com/kane-ai"
  url "https://registry.npmjs.org/@testmuai/kane-cli/-/kane-cli-0.2.6.tgz"
  sha256 "89e6793377d6a2732a52c3c7c8c6f5f2582f5cb5bb8a473ea2a9d60cbe56402e"
  license "Apache-2.0"
  version "0.2.6"

  depends_on "node"

  def install
    system "npm", "install", *std_npm_args
    bin.install_symlink libexec.glob("bin/*")

    # `npm install` triggers two automatic behaviors here:
    #
    # 1. optionalDependencies resolves to the matching platform binary package
    #    (@testmuai/kane-cli-{darwin-arm64,linux-x64,win-x64}). npm installs only
    #    the one for the current platform; others are silently skipped.
    #
    # 2. The postinstall hook (scripts/install-chrome.cjs, ships with 0.3.0+)
    #    downloads a pinned Chrome-for-Testing build to the user's cache dir
    #    (~/.cache/kane-cli/chrome on macOS/Linux). Failures are non-fatal — see
    #    KANE_CLI_SKIP_BROWSER_DOWNLOAD and KANE_CLI_CHROME_PATH in the caveats
    #    below for opt-outs. Recovery: `kane-cli doctor --install-browser`.
  end

  def caveats
    <<~EOS
      Currently supported platforms: macOS ARM64 (Apple Silicon) and Linux x64.
      Intel Mac and ARM Linux binaries are not yet available.

      On first install, kane-cli downloads a known-good Chrome-for-Testing build
      (~150 MB) to ~/.cache/kane-cli/chrome. Subsequent installs reuse the cache.

      Skip the Chrome download (CI / air-gapped environments):
        KANE_CLI_SKIP_BROWSER_DOWNLOAD=1 brew install LambdaTest/kane/kane-cli

      Use an existing Chrome binary instead:
        KANE_CLI_CHROME_PATH=/path/to/chrome brew install LambdaTest/kane/kane-cli

      The Chrome cache survives `brew uninstall`. Remove it manually with:
        rm -rf ~/.cache/kane-cli
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kane-cli --version")
  end
end
