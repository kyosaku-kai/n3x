#!/usr/bin/env bash
# isar-build-all - Build ISAR images from the build matrix and register in Nix store
#
# Reads variant definitions from nix eval, builds each variant with kas-build,
# renames output files to unique names, hashes them, adds to nix store,
# and updates lib/debian/artifact-hashes.nix.
#
# Usage:
#   nix run '.#isar-build-all'                    # Build all variants
#   nix run '.#isar-build-all' -- --variant server-simple-server-1  # One variant
#   nix run '.#isar-build-all' -- --machine qemuamd64               # One machine
#   nix run '.#isar-build-all' -- --list                             # List variants
#   nix run '.#isar-build-all' -- --dry-run                          # Show commands
#   nix run '.#isar-build-all' -- --rename-existing                  # Rename existing build outputs

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_NAME="isar-build-all"
REPO_ROOT="$(pwd)"
HASHES_FILE="${REPO_ROOT}/lib/debian/artifact-hashes.nix"
DEPLOY_BASE="${REPO_ROOT}/backends/debian/build/tmp/deploy/images"

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} ${BOLD}$*${NC}"; }

# =============================================================================
# Variant data loading
# =============================================================================

# Load all variant data from Nix eval as JSON
load_variants() {
  # shellcheck disable=SC2016 # Single quotes are intentional - this is a Nix expression, not shell
  nix eval --json '.#lib.debian.buildMatrix' --apply '
    matrix: builtins.map (v: {
      id = matrix.mkVariantId v;
      machine = v.machine;
      role = v.role;
      profile = v.profile or null;
      node = v.node or null;
      variant = v.variant or null;
      kasCommand = matrix.mkKasCommand v;
      artifactNames = builtins.map (at: {
        type = at;
        uniqueName = matrix.mkArtifactName v at;
        isarName = matrix.mkIsarOutputName v at;
      }) (builtins.attrNames (matrix.machines.${v.machine}).artifactTypes);
    }) matrix.variants
  '
}

# =============================================================================
# Help text
# =============================================================================

show_usage() {
  cat << EOF
${BOLD}${SCRIPT_NAME}${NC} - Build ISAR images from the build matrix

${BOLD}USAGE:${NC}
    ${SCRIPT_NAME} [OPTIONS]

${BOLD}OPTIONS:${NC}
    --variant ID          Build only this variant (e.g., server-simple-server-1)
    --machine MACHINE     Build only variants for this machine
    --overlay PATH        Append extra kas overlay to every build (e.g., kas/opt/debian-snapshot.yml)
    --list                List all variants and exit
    --dry-run             Show what would be done without executing
    --rename-existing     Skip build, rename existing deploy artifacts to unique names
    --hash-only           Skip build, just hash and register existing uniquely-named files
    --no-color            Disable colored output
    -h, --help            Show this help message

${BOLD}EXAMPLES:${NC}
    # Build everything
    ${SCRIPT_NAME}

    # Build one specific variant
    ${SCRIPT_NAME} --variant server-simple-server-1

    # Build all qemuamd64 variants
    ${SCRIPT_NAME} --machine qemuamd64

    # List all variants
    ${SCRIPT_NAME} --list

    # Migration: rename existing build outputs to unique names
    ${SCRIPT_NAME} --rename-existing

    # Re-hash already-renamed files
    ${SCRIPT_NAME} --hash-only

${BOLD}WORKFLOW:${NC}
    1. Build: kas-build with the variant's overlay chain
    2. Rename: copy ISAR output to unique filename
    3. Hash: compute SHA256 with nix-hash
    4. Store: add to nix store with nix-store --add-fixed
    5. Update: write new hash to lib/isar/artifact-hashes.nix
EOF
}

# =============================================================================
# Main operations
# =============================================================================

# List all variants
cmd_list() {
  local variants_json
  variants_json=$(load_variants)

  echo -e "${BOLD}ISAR Build Matrix Variants${NC}"
  echo "=========================="
  echo ""

  echo "${variants_json}" | jq -r '.[] | "\(.id)\t\(.machine)\t\(.role)\t\(.profile // "-")\t\(.node // "-")"' | \
    column -t -s $'\t' -N "VARIANT,MACHINE,ROLE,PROFILE,NODE"

  echo ""
  echo "Total: $(echo "${variants_json}" | jq 'length') variants"
}

# Build and register a single variant
process_variant() {
  local variant_json="$1"
  local dry_run="${2:-false}"
  local skip_build="${3:-false}"
  local rename_existing="${4:-false}"

  local id machine kas_cmd
  id=$(echo "${variant_json}" | jq -r '.id')
  machine=$(echo "${variant_json}" | jq -r '.machine')
  kas_cmd=$(echo "${variant_json}" | jq -r '.kasCommand')

  local deploy_dir="${DEPLOY_BASE}/${machine}"
  local extra_overlay="${5:-}"

  # Append extra overlay to kas command if specified
  local full_kas_cmd="${kas_cmd}"
  if [[ -n "${extra_overlay}" ]]; then
    full_kas_cmd="${kas_cmd}:${extra_overlay}"
  fi

  echo ""
  log_step "Processing variant: ${id} (${machine})"

  # Step 1: Build (unless skip_build or rename_existing)
  if ! ${skip_build} && ! ${rename_existing}; then
    log_info "Building: kas-build ${full_kas_cmd}"
    if ${dry_run}; then
      echo "  [DRY-RUN] Would run: nix develop '.' -c bash -c \"cd backends/debian && kas-build ${full_kas_cmd}\""
    else
      nix develop '.' -c bash -c "cd backends/debian && kas-build ${full_kas_cmd}"
    fi
  fi

  # Step 2-5: For each artifact type, rename/hash/store/update
  local artifact_count
  artifact_count=$(echo "${variant_json}" | jq '.artifactNames | length')

  for i in $(seq 0 $((artifact_count - 1))); do
    local unique_name isar_name
    unique_name=$(echo "${variant_json}" | jq -r ".artifactNames[${i}].uniqueName")
    isar_name=$(echo "${variant_json}" | jq -r ".artifactNames[${i}].isarName")

    local isar_path="${deploy_dir}/${isar_name}"
    local unique_path="${deploy_dir}/${unique_name}"

    # Step 2: Rename (copy) ISAR output to unique name
    if ${rename_existing}; then
      if ${dry_run}; then
        echo "  [DRY-RUN] Would copy: ${isar_name} -> ${unique_name}"
        [[ ! -f "${isar_path}" ]] && log_warn "Source not present: ${isar_name}"
      elif [[ -f "${isar_path}" ]]; then
        cp "${isar_path}" "${unique_path}"
        log_info "Copied: ${isar_name} -> ${unique_name}"
      else
        log_warn "ISAR output not found: ${isar_path}"
        continue
      fi
    elif ! ${skip_build}; then
      # After a fresh build, copy to unique name
      if ${dry_run}; then
        echo "  [DRY-RUN] Would copy: ${isar_name} -> ${unique_name}"
        [[ ! -f "${isar_path}" ]] && log_warn "Not yet built: ${isar_name}"
      elif [[ -f "${isar_path}" ]]; then
        cp "${isar_path}" "${unique_path}"
        log_info "Copied: ${isar_name} -> ${unique_name}"
      else
        log_warn "Build output not found: ${isar_path}"
        continue
      fi
    fi

    # Step 3: Hash
    if ${dry_run}; then
      echo "  [DRY-RUN] Would hash: ${unique_name}"
      echo "  [DRY-RUN] Would add to nix store"
      echo "  [DRY-RUN] Would update ${HASHES_FILE}"
      continue
    fi

    if [[ ! -f "${unique_path}" ]]; then
      log_warn "Unique-named file not found: ${unique_path}"
      continue
    fi

    local hash
    hash=$(nix-hash --type sha256 --flat --base32 "${unique_path}")
    log_info "Hash: ${unique_name} = ${hash}"

    # Step 4: Add to nix store
    local store_path
    store_path=$(nix-store --add-fixed sha256 "${unique_path}")
    log_info "Store: ${store_path}"

    # Step 5: Update hashes file
    update_hash "${unique_name}" "${hash}"
    log_success "Registered: ${unique_name}"
  done
}

# Update a single hash in artifact-hashes.nix
update_hash() {
  local artifact_name="$1"
  local new_hash="$2"

  # Escape dots for sed pattern
  local escaped_name="${artifact_name//./\\.}"

  # Replace the hash value for this artifact name
  sed -i "s|\"${escaped_name}\" = \"[^\"]*\"|\"${escaped_name}\" = \"${new_hash}\"|" "${HASHES_FILE}"
}

# =============================================================================
# Main entry point
# =============================================================================

main() {
  local filter_variant=""
  local filter_machine=""
  local extra_overlay=""
  local dry_run=false
  local do_list=false
  local skip_build=false
  local rename_existing=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)      filter_variant="$2"; shift 2 ;;
      --machine)      filter_machine="$2"; shift 2 ;;
      --overlay)      extra_overlay="$2"; shift 2 ;;
      --list)         do_list=true; shift ;;
      --dry-run)      dry_run=true; shift ;;
      --rename-existing) rename_existing=true; skip_build=true; shift ;;
      --hash-only)    skip_build=true; shift ;;
      --no-color)     RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''; shift ;;
      -h|--help)      show_usage; exit 0 ;;
      *)              log_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
  done

  # Validate we're in the right directory
  if [[ ! -f "${REPO_ROOT}/flake.nix" ]]; then
    log_error "Must be run from repository root (no flake.nix found)"
    exit 1
  fi

  if [[ ! -f "${HASHES_FILE}" ]]; then
    log_error "Hashes file not found: ${HASHES_FILE}"
    exit 1
  fi

  # List mode
  if ${do_list}; then
    cmd_list
    exit 0
  fi

  # Load variants
  log_info "Loading build matrix from flake..."
  local variants_json
  variants_json=$(load_variants)

  local total
  total=$(echo "${variants_json}" | jq 'length')
  log_info "Found ${total} variants in matrix"

  # Filter if requested
  if [[ -n "${filter_variant}" ]]; then
    variants_json=$(echo "${variants_json}" | jq --arg id "${filter_variant}" '[.[] | select(.id == $id)]')
    local filtered
    filtered=$(echo "${variants_json}" | jq 'length')
    if [[ "${filtered}" == "0" ]]; then
      log_error "No variant found with ID: ${filter_variant}"
      log_info "Use --list to see available variants"
      exit 1
    fi
    log_info "Filtered to ${filtered} variant(s) matching: ${filter_variant}"
  fi

  if [[ -n "${filter_machine}" ]]; then
    variants_json=$(echo "${variants_json}" | jq --arg m "${filter_machine}" '[.[] | select(.machine == $m)]')
    local filtered
    filtered=$(echo "${variants_json}" | jq 'length')
    if [[ "${filtered}" == "0" ]]; then
      log_error "No variants found for machine: ${filter_machine}"
      exit 1
    fi
    log_info "Filtered to ${filtered} variant(s) for machine: ${filter_machine}"
  fi

  # Process each variant
  local count=0
  local variant_count
  variant_count=$(echo "${variants_json}" | jq 'length')

  for i in $(seq 0 $((variant_count - 1))); do
    local variant
    variant=$(echo "${variants_json}" | jq ".[$i]")
    count=$((count + 1))

    echo ""
    echo -e "${BOLD}[${count}/${variant_count}]${NC}"
    process_variant "${variant}" "${dry_run}" "${skip_build}" "${rename_existing}" "${extra_overlay}"
  done

  echo ""
  echo "============================================"
  if ${dry_run}; then
    log_info "Dry run complete. No changes made."
  else
    log_success "All ${variant_count} variants processed!"
    echo ""
    echo "Next steps:"
    echo "  1. Review: git diff ${HASHES_FILE}"
    echo "  2. Stage:  git add ${HASHES_FILE}"
    echo "  3. Verify: nix flake check --no-build"
    echo "  4. Test:   nix build '.#checks.x86_64-linux.isar-all' -L"
  fi
}

main "$@"
