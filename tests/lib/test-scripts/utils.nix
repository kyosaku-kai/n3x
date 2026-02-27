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
  # Note: 'time' import removed in Phase A (Plan 019) - replaced with wait_until_succeeds
  imports = ''
    import datetime
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

  # Resilient command execution with retry and diagnostic output capture.
  # Uses machine.execute() instead of machine.succeed() so that output is
  # preserved on failure (succeed() throws RequestedAssertionFailed which
  # loses stderr/stdout). Includes sync + settle delay for filesystem ops.
  #
  # Usage:
  #   run_with_retry(testvm, "swupdate -v -k cert.pem -i bundle.swu",
  #                  max_attempts=3, delay=2, settle=1,
  #                  success_check=lambda code, out: code == 0)
  runWithRetry = ''
    def run_with_retry(machine, cmd, max_attempts=3, delay=2, settle=0,
                       success_check=None, description=None):
        """Execute a command with retry, capturing output on all attempts.

        Args:
            machine: NixOS test driver machine object
            cmd: Shell command to execute
            max_attempts: Number of attempts before raising
            delay: Seconds between retries
            settle: Seconds to wait before first attempt (for filesystem sync)
            success_check: Optional callable(exit_code, output) -> bool.
                           Default: exit_code == 0
            description: Human-readable label for log messages

        Returns:
            Output string from the successful attempt.

        Raises:
            Exception with full diagnostic output if all attempts fail.
        """
        import time

        if success_check is None:
            success_check = lambda code, out: code == 0

        label = description or cmd[:60]

        if settle > 0:
            time.sleep(settle)

        last_code = None
        last_output = None
        for attempt in range(max_attempts):
            last_code, last_output = machine.execute(f"{cmd} 2>&1")
            if success_check(last_code, last_output):
                if attempt > 0:
                    print(f"  {label}: succeeded on attempt {attempt + 1}")
                return last_output
            print(f"  {label}: attempt {attempt + 1}/{max_attempts} "
                  f"failed (exit={last_code})")
            if attempt < max_attempts - 1:
                time.sleep(delay)

        raise Exception(
            f"{label}: failed after {max_attempts} attempts "
            f"(last exit code {last_code}).\n"
            f"Last output:\n{last_output}"
        )
  '';

  # All utilities combined (convenience export)
  all = ''
    import datetime

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

    def run_with_retry(machine, cmd, max_attempts=3, delay=2, settle=0,
                       success_check=None, description=None):
        """Execute a command with retry, capturing output on all attempts.

        Args:
            machine: NixOS test driver machine object
            cmd: Shell command to execute
            max_attempts: Number of attempts before raising
            delay: Seconds between retries
            settle: Seconds to wait before first attempt (for filesystem sync)
            success_check: Optional callable(exit_code, output) -> bool.
                           Default: exit_code == 0
            description: Human-readable label for log messages

        Returns:
            Output string from the successful attempt.

        Raises:
            Exception with full diagnostic output if all attempts fail.
        """
        import time

        if success_check is None:
            success_check = lambda code, out: code == 0

        label = description or cmd[:60]

        if settle > 0:
            time.sleep(settle)

        last_code = None
        last_output = None
        for attempt in range(max_attempts):
            last_code, last_output = machine.execute(f"{cmd} 2>&1")
            if success_check(last_code, last_output):
                if attempt > 0:
                    print(f"  {label}: succeeded on attempt {attempt + 1}")
                return last_output
            print(f"  {label}: attempt {attempt + 1}/{max_attempts} "
                  f"failed (exit={last_code})")
            if attempt < max_attempts - 1:
                time.sleep(delay)

        raise Exception(
            f"{label}: failed after {max_attempts} attempts "
            f"(last exit code {last_code}).\n"
            f"Last output:\n{last_output}"
        )
  '';
}
