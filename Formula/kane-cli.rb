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
  depends_on cask: "google-chrome"

  def install
    system "npm", "install", *std_npm_args
    bin.install_symlink libexec.glob("bin/*")

    # `npm install` resolves the optionalDependencies block in the meta package
    # (@testmuai/kane-cli-{darwin-arm64,linux-x64,win-x64}) and pulls only the
    # platform-specific native runner binary; others are silently skipped.
    #
    # Chrome is installed by `depends_on cask: "google-chrome"` above, before
    # this block runs. kane-cli verifies Chrome is reachable at runtime via
    # the gate in src/orchestration/prepare-chrome.ts — produces a clean
    # actionable error if Chrome is missing or moved.
  end

  def caveats
    <<~EOS
      Currently supported platforms: macOS ARM64 (Apple Silicon) and Linux x64.
      Intel Mac and ARM Linux binaries are not yet available.

      kane-cli requires Google Chrome at /Applications/Google Chrome.app.
      Homebrew installs it automatically via the `google-chrome` cask
      declared as a dependency.

      To use an existing Chrome at a non-standard path:
        export KANE_CLI_CHROME_PATH=/path/to/chrome
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/kane-cli --version")
  end
end
