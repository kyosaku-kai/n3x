#!/usr/bin/env bash
# rebuild-isar-artifacts - Build ISAR images and register them in Nix store
#
# This script automates the full ISAR artifact lifecycle:
#   1. Build image using kas-container
#   2. Compute SHA256 hash
#   3. Add to Nix store
#   4. Update nix/isar-artifacts.nix with new hash
#
# Shell completion support:
#   - Bash: eval "$(rebuild-isar-artifacts --completion bash)"
#   - Zsh:  eval "$(rebuild-isar-artifacts --completion zsh)"
#
# See ADR 001 for architectural context: docs/adr/001-isar-artifact-integration-architecture.md

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_NAME="rebuild-isar-artifacts"
VERSION="1.0.0"

# Valid machines and their kas YAML files
declare -A MACHINES=(
  ["qemuamd64"]="qemu-amd64"
  ["qemuarm64"]="qemu-arm64"
  ["jetson-orin-nano"]="jetson-orin-nano"
  ["amd-v3c18i"]="amd-v3c18i"
)

# Valid roles and their image targets
declare -A ROLES=(
  ["base"]="minimal-base"
  ["server"]="k3s-server"
  ["agent"]="k3s-agent"
)

# Additional kas overlays for specific configurations
declare -A OVERLAYS=(
  ["test"]="test-overlay"           # Adds nixos-test-backdoor for VM testing
  ["test-k3s"]="test-k3s-overlay"   # test + k3s for k3s VM tests
  ["swupdate"]="feature/swupdate"   # A/B partition layout for OTA
  ["simple"]="network/simple"       # Simple flat network (default)
  ["vlans"]="network/vlans"         # 802.1Q VLAN tagging
  ["bonding-vlans"]="network/bonding-vlans"  # Bonding + VLANs
)

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Logging utilities
# =============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} ${BOLD}$*${NC}"; }

# =============================================================================
# Shell completion generators
# =============================================================================

generate_bash_completion() {
  cat << 'BASH_COMPLETION'
_rebuild_isar_artifacts() {
    local cur prev words cword
    _init_completion || return

    local machines="qemuamd64 qemuarm64 jetson-orin-nano amd-v3c18i"
    local roles="base server agent"
    local overlays="test test-k3s swupdate simple vlans bonding-vlans"
    local commands="build list hash add update all"
    local global_opts="--help --version --dry-run --verbose --no-color --completion"

    case "$prev" in
        --completion)
            COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
            return
            ;;
        -m|--machine)
            COMPREPLY=( $(compgen -W "$machines" -- "$cur") )
            return
            ;;
        -r|--role)
            COMPREPLY=( $(compgen -W "$roles" -- "$cur") )
            return
            ;;
        -o|--overlay)
            COMPREPLY=( $(compgen -W "$overlays" -- "$cur") )
            return
            ;;
        rebuild-isar-artifacts)
            COMPREPLY=( $(compgen -W "$commands $global_opts" -- "$cur") )
            return
            ;;
    esac

    case "${words[1]}" in
        build|hash|add|update|all)
            case "$cur" in
                -*)
                    COMPREPLY=( $(compgen -W "-m --machine -r --role -o --overlay --dry-run --verbose" -- "$cur") )
                    ;;
                *)
                    # After command, suggest options
                    COMPREPLY=( $(compgen -W "-m --machine -r --role -o --overlay" -- "$cur") )
                    ;;
            esac
            ;;
        list)
            COMPREPLY=( $(compgen -W "--machines --roles --overlays --all" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "$commands $global_opts" -- "$cur") )
            ;;
    esac
}

complete -F _rebuild_isar_artifacts rebuild-isar-artifacts
BASH_COMPLETION
}

generate_zsh_completion() {
  cat << 'ZSH_COMPLETION'
#compdef rebuild-isar-artifacts

_rebuild_isar_artifacts() {
    local -a commands machines roles overlays

    commands=(
        'build:Build ISAR image using kas-container'
        'list:List available machines, roles, and overlays'
        'hash:Compute SHA256 hash of built artifact'
        'add:Add artifact to Nix store'
        'update:Update nix/isar-artifacts.nix with hash'
        'all:Build, hash, add to store, and update nix file'
    )

    machines=(
        'qemuamd64:QEMU x86_64 for VM testing'
        'qemuarm64:QEMU ARM64 for Jetson emulation'
        'jetson-orin-nano:NVIDIA Jetson Orin Nano hardware'
        'amd-v3c18i:AMD V3C18i edge compute hardware'
    )

    roles=(
        'base:Minimal base image without K3s'
        'server:K3s server/control plane node'
        'agent:K3s agent/worker node'
    )

    overlays=(
        'test:Add nixos-test-backdoor for VM testing'
        'test-k3s:Test overlay plus K3s components'
        'swupdate:A/B partition layout for OTA updates'
        'simple:Simple flat network configuration'
        'vlans:802.1Q VLAN tagging'
        'bonding-vlans:Bonding plus VLANs'
    )

    _arguments -C \
        '1:command:->command' \
        '*::arg:->args' \
        '--help[Show help message]' \
        '--version[Show version]' \
        '--dry-run[Show what would be done without executing]' \
        '--verbose[Enable verbose output]' \
        '--no-color[Disable colored output]' \
        '--completion[Generate shell completion]:shell:(bash zsh fish)'

    case "$state" in
        command)
            _describe -t commands 'command' commands
            ;;
        args)
            case "${words[1]}" in
                build|hash|add|update|all)
                    _arguments \
                        '(-m --machine)'{-m,--machine}'[Target machine]:machine:->machines' \
                        '(-r --role)'{-r,--role}'[Image role]:role:->roles' \
                        '(-o --overlay)'{-o,--overlay}'[Additional overlay]:overlay:->overlays' \
                        '--dry-run[Show what would be done]' \
                        '--verbose[Verbose output]'

                    case "$state" in
                        machines)
                            _describe -t machines 'machine' machines
                            ;;
                        roles)
                            _describe -t roles 'role' roles
                            ;;
                        overlays)
                            _describe -t overlays 'overlay' overlays
                            ;;
                    esac
                    ;;
                list)
                    _arguments \
                        '--machines[List available machines]' \
                        '--roles[List available roles]' \
                        '--overlays[List available overlays]' \
                        '--all[List everything]'
                    ;;
            esac
            ;;
    esac
}

_rebuild_isar_artifacts "$@"
ZSH_COMPLETION
}

generate_fish_completion() {
  cat << 'FISH_COMPLETION'
# Fish completion for rebuild-isar-artifacts

set -l commands build list hash add update all

# Global options
complete -c rebuild-isar-artifacts -l help -d 'Show help message'
complete -c rebuild-isar-artifacts -l version -d 'Show version'
complete -c rebuild-isar-artifacts -l dry-run -d 'Show what would be done'
complete -c rebuild-isar-artifacts -l verbose -d 'Enable verbose output'
complete -c rebuild-isar-artifacts -l no-color -d 'Disable colored output'
complete -c rebuild-isar-artifacts -l completion -xa 'bash zsh fish' -d 'Generate shell completion'

# Commands
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a build -d 'Build ISAR image'
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a list -d 'List available options'
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a hash -d 'Compute artifact hash'
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a add -d 'Add to Nix store'
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a update -d 'Update nix file'
complete -c rebuild-isar-artifacts -n "not __fish_seen_subcommand_from $commands" -a all -d 'Full rebuild workflow'

# Machine options
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from build hash add update all" -s m -l machine -xa 'qemuamd64 qemuarm64 jetson-orin-nano amd-v3c18i' -d 'Target machine'

# Role options
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from build hash add update all" -s r -l role -xa 'base server agent' -d 'Image role'

# Overlay options
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from build hash add update all" -s o -l overlay -xa 'test test-k3s swupdate simple vlans bonding-vlans' -d 'Additional overlay'

# List subcommand options
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from list" -l machines -d 'List machines'
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from list" -l roles -d 'List roles'
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from list" -l overlays -d 'List overlays'
complete -c rebuild-isar-artifacts -n "__fish_seen_subcommand_from list" -l all -d 'List everything'
FISH_COMPLETION
}

# =============================================================================
# Help text
# =============================================================================

show_usage() {
  cat << EOF
${BOLD}$SCRIPT_NAME${NC} - Build ISAR images and register them in Nix store

${BOLD}USAGE:${NC}
    $SCRIPT_NAME COMMAND [OPTIONS]
    $SCRIPT_NAME [GLOBAL-OPTIONS]

${BOLD}DESCRIPTION:${NC}
    Automates the ISAR artifact lifecycle for Nix integration:
    - Builds disk images using kas-container
    - Computes content-addressable SHA256 hashes
    - Registers artifacts in the Nix store
    - Updates nix/isar-artifacts.nix with new hashes

    See docs/adr/001-isar-artifact-integration-architecture.md for context.

${BOLD}COMMANDS:${NC}
    build       Build ISAR image using kas-container
    list        List available machines, roles, and overlays
    hash        Compute SHA256 hash of existing artifact
    add         Add existing artifact to Nix store
    update      Update nix/isar-artifacts.nix with computed hash
    all         Full workflow: build + hash + add + update

${BOLD}GLOBAL OPTIONS:${NC}
    -h, --help              Show this help message
    -V, --version           Show version information
    --dry-run               Show what would be done without executing
    --verbose               Enable verbose output
    --no-color              Disable colored output
    --completion SHELL      Generate shell completion (bash, zsh, fish)

${BOLD}COMMAND OPTIONS:${NC}
    -m, --machine MACHINE   Target machine (required for most commands)
    -r, --role ROLE         Image role (default: base)
    -o, --overlay OVERLAY   Additional kas overlay (optional, repeatable)

${BOLD}MACHINES:${NC}
    qemuamd64               QEMU x86_64 - VM testing on x86 hosts
    qemuarm64               QEMU ARM64 - Jetson emulation, ARM testing
    jetson-orin-nano        NVIDIA Jetson Orin Nano - real hardware
    amd-v3c18i              AMD V3C18i - edge compute hardware

${BOLD}ROLES:${NC}
    base                    Minimal base image without K3s
    server                  K3s server (control plane) node
    agent                   K3s agent (worker) node

${BOLD}OVERLAYS:${NC}
    test                    Add nixos-test-backdoor for VM testing
    test-k3s                Test overlay + K3s for k3s VM tests
    swupdate                A/B partition layout for OTA updates
    simple                  Simple flat network configuration
    vlans                   802.1Q VLAN tagging
    bonding-vlans           Bonding plus VLANs

${BOLD}EXAMPLES:${NC}
    # Build qemuamd64 server image for testing
    $SCRIPT_NAME build -m qemuamd64 -r server -o test-k3s

    # Full workflow: build, hash, add to store, update nix file
    $SCRIPT_NAME all -m qemuamd64 -r server -o test-k3s

    # Just compute and display hash of existing artifact
    $SCRIPT_NAME hash -m qemuamd64 -r server

    # Add existing artifact to nix store
    $SCRIPT_NAME add -m qemuamd64 -r server

    # Update nix file with hash of existing artifact
    $SCRIPT_NAME update -m qemuamd64 -r server

    # List all available options
    $SCRIPT_NAME list --all

    # Install shell completions
    eval "\$($SCRIPT_NAME --completion bash)"   # Bash
    eval "\$($SCRIPT_NAME --completion zsh)"    # Zsh
    $SCRIPT_NAME --completion fish > ~/.config/fish/completions/$SCRIPT_NAME.fish

${BOLD}WORKFLOW:${NC}
    The typical workflow after making ISAR recipe changes:

    1. Build the image:
       $SCRIPT_NAME build -m qemuamd64 -r server -o test-k3s

    2. Register in Nix (or use 'all' to do everything):
       $SCRIPT_NAME all -m qemuamd64 -r server -o test-k3s

    3. Verify:
       nix flake check --no-build

    4. Run tests:
       nix build '.#checks.x86_64-linux.isar-k3s-service-starts'

Run '$SCRIPT_NAME COMMAND --help' for command-specific help.
EOF
}

show_build_help() {
  cat << EOF
${BOLD}$SCRIPT_NAME build${NC} - Build ISAR image using kas-container

${BOLD}USAGE:${NC}
    $SCRIPT_NAME build -m MACHINE [-r ROLE] [-o OVERLAY...]

${BOLD}OPTIONS:${NC}
    -m, --machine MACHINE   Target machine (required)
    -r, --role ROLE         Image role (default: base)
    -o, --overlay OVERLAY   Additional overlay (can be repeated)
    --dry-run               Show kas command without executing
    --verbose               Show detailed build output

${BOLD}DESCRIPTION:${NC}
    Runs kas-container to build an ISAR image. The kas configuration is
    assembled from:
    - kas/base.yml (always included)
    - kas/machine/<machine>.yml
    - kas/image/<role>.yml
    - kas/<overlay>.yml (for each overlay specified)

${BOLD}EXAMPLES:${NC}
    # Build basic qemuamd64 base image
    $SCRIPT_NAME build -m qemuamd64

    # Build server image with test backdoor for VM testing
    $SCRIPT_NAME build -m qemuamd64 -r server -o test-k3s

    # Build jetson image with SWUpdate support
    $SCRIPT_NAME build -m jetson-orin-nano -r server -o swupdate

${BOLD}OUTPUT:${NC}
    Build artifacts are placed in:
    build/tmp/deploy/images/<machine>/

    For qemuamd64/qemuarm64: .wic, -vmlinuz/-vmlinux, -initrd.img
    For jetson-orin-nano: .tar.gz (rootfs tarball for L4T flash)
    For amd-v3c18i: .wic
EOF
}

show_list_help() {
  cat << EOF
${BOLD}$SCRIPT_NAME list${NC} - List available machines, roles, and overlays

${BOLD}USAGE:${NC}
    $SCRIPT_NAME list [--machines] [--roles] [--overlays] [--all]

${BOLD}OPTIONS:${NC}
    --machines      List available target machines
    --roles         List available image roles
    --overlays      List available kas overlays
    --all           List everything (default if no option given)

${BOLD}EXAMPLES:${NC}
    $SCRIPT_NAME list --machines
    $SCRIPT_NAME list --all
EOF
}

# =============================================================================
# Utility functions
# =============================================================================

# Get artifact path for a machine/role combination
get_artifact_path() {
  local machine="$1"
  local role="$2"
  local deploy_dir="build/tmp/deploy/images"

  local recipe_name
  case "$role" in
    base)   recipe_name="base" ;;
    server) recipe_name="server" ;;
    agent)  recipe_name="agent" ;;
    *)      log_error "Unknown role: $role"; return 1 ;;
  esac

  local machine_dir
  case "$machine" in
    qemuamd64)        machine_dir="qemuamd64" ;;
    qemuarm64)        machine_dir="qemuarm64" ;;
    jetson-orin-nano) machine_dir="jetson-orin-nano" ;;
    amd-v3c18i)       machine_dir="amd-v3c18i" ;;
    *)                log_error "Unknown machine: $machine"; return 1 ;;
  esac

  # Determine artifact type based on machine
  local artifact_ext
  case "$machine" in
    qemuamd64|amd-v3c18i)
      artifact_ext="wic"
      ;;
    qemuarm64)
      artifact_ext="ext4"
      ;;
    jetson-orin-nano)
      artifact_ext="tar.gz"
      ;;
  esac

  echo "$deploy_dir/$machine_dir/isar-k3s-image-${recipe_name}-debian-trixie-${machine_dir}.${artifact_ext}"
}

# Get artifact name for nix file lookup
get_artifact_name() {
  local machine="$1"
  local role="$2"

  local recipe_name
  case "$role" in
    base)   recipe_name="base" ;;
    server) recipe_name="server" ;;
    agent)  recipe_name="agent" ;;
  esac

  local machine_dir
  case "$machine" in
    qemuamd64)        machine_dir="qemuamd64" ;;
    qemuarm64)        machine_dir="qemuarm64" ;;
    jetson-orin-nano) machine_dir="jetson-orin-nano" ;;
    amd-v3c18i)       machine_dir="amd-v3c18i" ;;
  esac

  local artifact_ext
  case "$machine" in
    qemuamd64|amd-v3c18i) artifact_ext="wic" ;;
    qemuarm64)            artifact_ext="ext4" ;;
    jetson-orin-nano)     artifact_ext="tar.gz" ;;
  esac

  echo "isar-k3s-image-${recipe_name}-debian-trixie-${machine_dir}.${artifact_ext}"
}

# Build kas configuration string
build_kas_config() {
  local machine="$1"
  local role="$2"
  shift 2
  local overlays=("$@")

  local kas_machine="${MACHINES[$machine]}"
  local kas_image="${ROLES[$role]}"

  local config="kas/base.yml:kas/machine/${kas_machine}.yml:kas/image/${kas_image}.yml"

  for overlay in "${overlays[@]}"; do
    if [[ -n "$overlay" ]]; then
      local kas_overlay="${OVERLAYS[$overlay]:-$overlay}"
      config="$config:kas/${kas_overlay}.yml"
    fi
  done

  echo "$config"
}

# Validate machine name
validate_machine() {
  local machine="$1"
  if [[ -z "${MACHINES[$machine]:-}" ]]; then
    log_error "Invalid machine: $machine"
    log_error "Valid machines: ${!MACHINES[*]}"
    return 1
  fi
}

# Validate role name
validate_role() {
  local role="$1"
  if [[ -z "${ROLES[$role]:-}" ]]; then
    log_error "Invalid role: $role"
    log_error "Valid roles: ${!ROLES[*]}"
    return 1
  fi
}

# =============================================================================
# Command implementations
# =============================================================================

cmd_list() {
  local show_machines=false
  local show_roles=false
  local show_overlays=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --machines)  show_machines=true; shift ;;
      --roles)     show_roles=true; shift ;;
      --overlays)  show_overlays=true; shift ;;
      --all)       show_machines=true; show_roles=true; show_overlays=true; shift ;;
      -h|--help)   show_list_help; exit 0 ;;
      *)           log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Default to showing all
  if ! $show_machines && ! $show_roles && ! $show_overlays; then
    show_machines=true
    show_roles=true
    show_overlays=true
  fi

  if $show_machines; then
    echo -e "${BOLD}MACHINES:${NC}"
    echo "  qemuamd64         QEMU x86_64 - VM testing on x86 hosts"
    echo "  qemuarm64         QEMU ARM64 - Jetson emulation, ARM testing"
    echo "  jetson-orin-nano  NVIDIA Jetson Orin Nano - real hardware"
    echo "  amd-v3c18i        AMD V3C18i - edge compute hardware"
    echo ""
  fi

  if $show_roles; then
    echo -e "${BOLD}ROLES:${NC}"
    echo "  base              Minimal base image without K3s"
    echo "  server            K3s server (control plane) node"
    echo "  agent             K3s agent (worker) node"
    echo ""
  fi

  if $show_overlays; then
    echo -e "${BOLD}OVERLAYS:${NC}"
    echo "  test              Add nixos-test-backdoor for VM testing"
    echo "  test-k3s          Test overlay + K3s for k3s VM tests"
    echo "  swupdate          A/B partition layout for OTA updates"
    echo "  simple            Simple flat network configuration"
    echo "  vlans             802.1Q VLAN tagging"
    echo "  bonding-vlans     Bonding plus VLANs"
    echo ""
  fi
}

cmd_build() {
  local machine=""
  local role="base"
  local overlays=()
  local dry_run=false
  local verbose=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--machine) machine="$2"; shift 2 ;;
      -r|--role)    role="$2"; shift 2 ;;
      -o|--overlay) overlays+=("$2"); shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      --verbose)    verbose=true; shift ;;
      -h|--help)    show_build_help; exit 0 ;;
      *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    log_error "Machine is required. Use -m/--machine"
    echo "Available machines: ${!MACHINES[*]}"
    exit 1
  fi

  validate_machine "$machine" || exit 1
  validate_role "$role" || exit 1

  local kas_config
  kas_config=$(build_kas_config "$machine" "$role" "${overlays[@]}")

  log_step "Building ISAR image"
  log_info "Machine: $machine"
  log_info "Role: $role"
  [[ ${#overlays[@]} -gt 0 ]] && log_info "Overlays: ${overlays[*]}"
  log_info "Kas config: $kas_config"
  echo ""

  if $dry_run; then
    echo "Would run: kas-build $kas_config"
    return 0
  fi

  # Use kas-build wrapper (handles WSL 9p workaround)
  if command -v kas-build &>/dev/null; then
    kas-build "$kas_config"
  else
    log_warn "kas-build wrapper not found, using kas-container directly"
    kas-container --isar build "$kas_config"
  fi

  local artifact_path
  artifact_path=$(get_artifact_path "$machine" "$role")

  if [[ -f "$artifact_path" ]]; then
    log_success "Build complete: $artifact_path"
  else
    log_error "Expected artifact not found: $artifact_path"
    exit 1
  fi
}

cmd_hash() {
  local machine=""
  local role="base"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--machine) machine="$2"; shift 2 ;;
      -r|--role)    role="$2"; shift 2 ;;
      -h|--help)    show_usage; exit 0 ;;
      *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    log_error "Machine is required. Use -m/--machine"
    exit 1
  fi

  validate_machine "$machine" || exit 1
  validate_role "$role" || exit 1

  local artifact_path
  artifact_path=$(get_artifact_path "$machine" "$role")

  if [[ ! -f "$artifact_path" ]]; then
    log_error "Artifact not found: $artifact_path"
    log_info "Build it first with: $SCRIPT_NAME build -m $machine -r $role"
    exit 1
  fi

  log_step "Computing SHA256 hash"
  log_info "Artifact: $artifact_path"

  local hash
  hash=$(nix-hash --type sha256 --flat --base32 "$artifact_path")

  echo ""
  echo -e "${BOLD}Hash:${NC} $hash"
  echo ""
  echo "Artifact: $(basename "$artifact_path")"
  echo "Size: $(du -h "$artifact_path" | cut -f1)"
}

cmd_add() {
  local machine=""
  local role="base"
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--machine) machine="$2"; shift 2 ;;
      -r|--role)    role="$2"; shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      -h|--help)    show_usage; exit 0 ;;
      *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    log_error "Machine is required. Use -m/--machine"
    exit 1
  fi

  validate_machine "$machine" || exit 1
  validate_role "$role" || exit 1

  local artifact_path
  artifact_path=$(get_artifact_path "$machine" "$role")

  if [[ ! -f "$artifact_path" ]]; then
    log_error "Artifact not found: $artifact_path"
    exit 1
  fi

  log_step "Adding artifact to Nix store"
  log_info "Artifact: $artifact_path"

  if $dry_run; then
    echo "Would run: nix-store --add-fixed sha256 $artifact_path"
    return 0
  fi

  local store_path
  store_path=$(nix-store --add-fixed sha256 "$artifact_path")

  log_success "Added to store: $store_path"
}

cmd_update() {
  local machine=""
  local role="base"
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--machine) machine="$2"; shift 2 ;;
      -r|--role)    role="$2"; shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      -h|--help)    show_usage; exit 0 ;;
      *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    log_error "Machine is required. Use -m/--machine"
    exit 1
  fi

  validate_machine "$machine" || exit 1
  validate_role "$role" || exit 1

  local artifact_path
  artifact_path=$(get_artifact_path "$machine" "$role")

  if [[ ! -f "$artifact_path" ]]; then
    log_error "Artifact not found: $artifact_path"
    exit 1
  fi

  local artifacts_file="isar-artifacts.nix"
  if [[ ! -f "$artifacts_file" ]]; then
    log_error "Artifacts file not found: $artifacts_file"
    exit 1
  fi

  log_step "Updating $artifacts_file"

  local hash
  hash=$(nix-hash --type sha256 --flat --base32 "$artifact_path")
  local artifact_name
  artifact_name=$(get_artifact_name "$machine" "$role")

  log_info "Artifact: $artifact_name"
  log_info "New hash: $hash"

  if $dry_run; then
    echo "Would update $artifacts_file:"
    echo "  name = \"$artifact_name\";"
    echo "  sha256 = \"$hash\";"
    return 0
  fi

  # Backup
  cp "$artifacts_file" "$artifacts_file.bak"

  # Update hash in nix file
  local escaped_name="${artifact_name//./\\.}"
  sed -i "/name = \"${escaped_name}\";/{n;s/sha256 = \"[^\"]*\";/sha256 = \"${hash}\";/}" "$artifacts_file"

  log_success "Updated $artifacts_file"
  log_info "Backup saved to: $artifacts_file.bak"
  echo ""
  echo "Review changes with: git diff $artifacts_file"
}

cmd_all() {
  local machine=""
  local role="base"
  local overlays=()
  local dry_run=false
  local verbose=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--machine) machine="$2"; shift 2 ;;
      -r|--role)    role="$2"; shift 2 ;;
      -o|--overlay) overlays+=("$2"); shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      --verbose)    verbose=true; shift ;;
      -h|--help)    show_usage; exit 0 ;;
      *)            log_error "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$machine" ]]; then
    log_error "Machine is required. Use -m/--machine"
    exit 1
  fi

  validate_machine "$machine" || exit 1
  validate_role "$role" || exit 1

  echo -e "${BOLD}Full ISAR Artifact Workflow${NC}"
  echo "=========================="
  log_info "Machine: $machine"
  log_info "Role: $role"
  [[ ${#overlays[@]} -gt 0 ]] && log_info "Overlays: ${overlays[*]}"
  echo ""

  # Build
  echo -e "${BOLD}Step 1/4: Build${NC}"
  local build_args=(-m "$machine" -r "$role")
  for o in "${overlays[@]}"; do
    build_args+=(-o "$o")
  done
  $dry_run && build_args+=(--dry-run)
  $verbose && build_args+=(--verbose)
  cmd_build "${build_args[@]}"
  echo ""

  # Hash
  echo -e "${BOLD}Step 2/4: Compute Hash${NC}"
  cmd_hash -m "$machine" -r "$role"
  echo ""

  # Add to store
  echo -e "${BOLD}Step 3/4: Add to Nix Store${NC}"
  local add_args=(-m "$machine" -r "$role")
  $dry_run && add_args+=(--dry-run)
  cmd_add "${add_args[@]}"
  echo ""

  # Update nix file
  echo -e "${BOLD}Step 4/4: Update nix/isar-artifacts.nix${NC}"
  local update_args=(-m "$machine" -r "$role")
  $dry_run && update_args+=(--dry-run)
  cmd_update "${update_args[@]}"
  echo ""

  log_success "Workflow complete!"
  echo ""
  echo "Next steps:"
  echo "  1. Review: git diff nix/isar-artifacts.nix"
  echo "  2. Stage:  git add nix/isar-artifacts.nix"
  echo "  3. Verify: nix flake check --no-build"
}

# =============================================================================
# Main entry point
# =============================================================================

main() {
  local command=""

  # Handle global options before command
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_usage
        exit 0
        ;;
      -V|--version)
        echo "$SCRIPT_NAME version $VERSION"
        exit 0
        ;;
      --no-color)
        # Disable color output by clearing ANSI escape codes
        RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
        shift
        ;;
      --completion)
        case "${2:-}" in
          bash) generate_bash_completion; exit 0 ;;
          zsh)  generate_zsh_completion; exit 0 ;;
          fish) generate_fish_completion; exit 0 ;;
          *)    log_error "Unknown shell: ${2:-}. Use bash, zsh, or fish"; exit 1 ;;
        esac
        ;;
      -*)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
      *)
        command="$1"
        shift
        break
        ;;
    esac
  done

  if [[ -z "$command" ]]; then
    show_usage
    exit 0
  fi

  case "$command" in
    build)  cmd_build "$@" ;;
    list)   cmd_list "$@" ;;
    hash)   cmd_hash "$@" ;;
    add)    cmd_add "$@" ;;
    update) cmd_update "$@" ;;
    all)    cmd_all "$@" ;;
    help)   show_usage ;;
    *)
      log_error "Unknown command: $command"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
}

main "$@"
