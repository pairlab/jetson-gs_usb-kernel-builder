#!/bin/bash
set -euo pipefail

# ==============================================================================
# Install built kernel modules onto a Jetson using modules.txt
#
# Expected modules file format:
#   module_name|config_symbol|module_dir
#
# Example:
#   gs_usb|CONFIG_CAN_GS_USB|drivers/net/can/usb
#   peak_usb|CONFIG_CAN_PEAK_USB|drivers/net/can/usb
#
# This script:
#   - reads modules from modules.txt
#   - copies <module>.ko into /lib/modules/$(uname -r)/kernel/<module-subdir>/
#   - optionally appends module names to /etc/modules
#   - runs depmod
#
# Usage examples:
#   ./install_modules_on_jetson.sh
#   ./install_modules_on_jetson.sh --modules-file modules.txt --source-dir .
#   ./install_modules_on_jetson.sh --dry-run
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_header() {
    echo -e "${YELLOW}\n===== $1 =====${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "[INFO] $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat <<EOF
Usage:
  $0 [--modules-file FILE] [--source-dir DIR] [--skip-etc-modules] [--dry-run]

Options:
  --modules-file FILE     Module definition file (default: modules.txt)
  --source-dir DIR        Directory containing built .ko files (default: current dir)
  --skip-etc-modules      Do not add module names to /etc/modules
  --dry-run               Print actions without making changes
  -h, --help              Show this help

Notes:
  - Must be run on the target Jetson
  - Expects built .ko files named <module>.ko in --source-dir
  - Installs into:
      /lib/modules/\$(uname -r)/kernel/<module-subdir>/
EOF
}

MODULES_FILE="modules.txt"
SOURCE_DIR="."
DRY_RUN=0
UPDATE_ETC_MODULES=1
TARGET_UNAME_R="$(uname -r)"
MODULE_BASE="/lib/modules/$TARGET_UNAME_R/kernel"

declare -a MODULE_ENTRIES=()

run_cmd() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --modules-file)
            if [[ $# -lt 2 ]]; then
                print_error "--modules-file requires a value"
                exit 1
            fi
            MODULES_FILE="$2"
            shift 2
            ;;
        --source-dir)
            if [[ $# -lt 2 ]]; then
                print_error "--source-dir requires a value"
                exit 1
            fi
            SOURCE_DIR="$2"
            shift 2
            ;;
        --skip-etc-modules)
            UPDATE_ETC_MODULES=0
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

validate_modules_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        print_error "Modules file not found: $file"
        exit 1
    fi

    MODULE_ENTRIES=()
    local line_no=0
    local valid_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        local trimmed
        trimmed="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" =~ ^# ]] && continue

        local module_name config_symbol module_dir extra
        IFS='|' read -r module_name config_symbol module_dir extra <<< "$trimmed"

        module_name="$(echo "${module_name:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        config_symbol="$(echo "${config_symbol:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        module_dir="$(echo "${module_dir:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        extra="$(echo "${extra:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        module_name="${module_name%$'\r'}"
        config_symbol="${config_symbol%$'\r'}"
        module_dir="${module_dir%$'\r'}"
        extra="${extra%$'\r'}"

        if [[ -n "$extra" || -z "$module_name" || -z "$config_symbol" || -z "$module_dir" ]]; then
            print_error "Invalid modules file entry at line $line_no: $line"
            print_error "Expected format: module_name|config_symbol|module_dir"
            exit 1
        fi

        MODULE_ENTRIES+=("${module_name}|${config_symbol}|${module_dir}")
        valid_count=$((valid_count + 1))
    done < "$file"

    if [[ $valid_count -eq 0 ]]; then
        print_error "No valid module entries found in $file"
        exit 1
    fi

    print_info "Modules found in $file:"
    local idx=0
    local entry
    for entry in "${MODULE_ENTRIES[@]}"; do
        idx=$((idx + 1))
        local module_name config_symbol module_dir
        IFS='|' read -r module_name config_symbol module_dir <<< "$entry"
        print_info "  [$idx] module_name=$module_name | config_symbol=$config_symbol | module_dir=$module_dir"
    done
}

ensure_module_in_etc_modules() {
    local module_name="$1"

    if [[ $UPDATE_ETC_MODULES -eq 0 ]]; then
        return 0
    fi

    if grep -q "^${module_name}$" /etc/modules; then
        print_info "$module_name already present in /etc/modules"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] echo \"$module_name\" | sudo tee -a /etc/modules >/dev/null"
    else
        echo "$module_name" | sudo tee -a /etc/modules >/dev/null
        print_success "$module_name added to /etc/modules"
    fi
}

install_modules() {
    print_header "INSTALLING MODULES"

    local entry
    for entry in "${MODULE_ENTRIES[@]}"; do
        local module_name config_symbol module_dir
        IFS='|' read -r module_name config_symbol module_dir <<< "$entry"

        local source_ko="$SOURCE_DIR/$module_name.ko"
        local install_subdir="${module_dir#drivers/}"
        local install_dir="$MODULE_BASE/$install_subdir"

        if [[ ! -f "$source_ko" && $DRY_RUN -eq 0 ]]; then
            print_error "Missing module file: $source_ko"
            exit 1
        fi

        print_step "Installing $module_name"
        print_info "  Source: $source_ko"
        print_info "  Target: $install_dir/"

        run_cmd sudo mkdir -p "$install_dir"
        run_cmd sudo cp -v "$source_ko" "$install_dir/"

        ensure_module_in_etc_modules "$module_name"
    done
}

finalize_install() {
    print_header "FINALIZING"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] sudo depmod -a"
        print_success "Dry run complete"
    else
        sudo depmod -a
        print_success "depmod completed"
        print_info "Reboot recommended before using the modules"
    fi
}

print_header "JETSON MODULE INSTALLER"
print_info "Detected target kernel release: $TARGET_UNAME_R"
print_info "Module install base: $MODULE_BASE"
print_info "Modules file: $MODULES_FILE"
print_info "Source directory: $SOURCE_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
    print_info "Dry run mode enabled"
fi

validate_modules_file "$MODULES_FILE"
install_modules
finalize_install

print_header "DONE"