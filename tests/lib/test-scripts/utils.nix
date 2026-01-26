# Shared Python utility functions for test scripts
#
# These are small, stateless helpers used across all test phases.
# Exported as raw Python strings for interpolation into test scripts.
#
# Usage in Nix:
#   let
#     utils = import ./test-scripts/utils.nix;
#   in ''
#     ${utils.imports}
#     ${utils.tlog}
#
#     tlog("Starting test...")
#   ''

{
  # Python imports needed by utilities
  imports = ''
    import datetime
    import time
  '';

  # Timestamped logging function
  # Usage: tlog("message")
  tlog = ''
    def tlog(msg):
        """Print timestamped log message for test output."""
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)
  '';

  # Section header helper
  # Usage: log_section("PHASE 1", "Booting nodes")
  logSection = ''
    def log_section(phase, description):
        """Print a formatted section header."""
        tlog("")
        tlog(f"[{phase}] {description}...")
  '';

  # Test banner helper
  # Usage: log_banner("K3s Cluster Test", "vlans", {"arch": "2 servers + 1 agent"})
  logBanner = ''
    def log_banner(title, profile, info=None):
        """Print a test banner with optional info dict."""
        tlog("=" * 70)
        tlog(f"{title} - Network Profile: {profile}")
        tlog("=" * 70)
        if info:
            for key, value in info.items():
                tlog(f"  {key}: {value}")
            tlog("=" * 70)
  '';

  # Test summary helper
  # Usage: log_summary("K3s Cluster Test", "vlans", ["All 3 nodes Ready", "CoreDNS running"])
  logSummary = ''
    def log_summary(title, profile, validations):
        """Print a test success summary."""
        tlog("")
        tlog("=" * 70)
        tlog(f"{title} ({profile} profile) - PASSED")
        tlog("=" * 70)
        tlog("Validated:")
        tlog(f"  - Network profile: {profile}")
        for item in validations:
            tlog(f"  - {item}")
        tlog("=" * 70)
  '';

  # All utilities combined (convenience export)
  all = ''
    import datetime
    import time

    def tlog(msg):
        """Print timestamped log message for test output."""
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", flush=True)

    def log_section(phase, description):
        """Print a formatted section header."""
        tlog("")
        tlog(f"[{phase}] {description}...")

    def log_banner(title, profile, info=None):
        """Print a test banner with optional info dict."""
        tlog("=" * 70)
        tlog(f"{title} - Network Profile: {profile}")
        tlog("=" * 70)
        if info:
            for key, value in info.items():
                tlog(f"  {key}: {value}")
            tlog("=" * 70)

    def log_summary(title, profile, validations):
        """Print a test success summary."""
        tlog("")
        tlog("=" * 70)
        tlog(f"{title} ({profile} profile) - PASSED")
        tlog("=" * 70)
        tlog("Validated:")
        tlog(f"  - Network profile: {profile}")
        for item in validations:
            tlog(f"  - {item}")
        tlog("=" * 70)
  '';
}
