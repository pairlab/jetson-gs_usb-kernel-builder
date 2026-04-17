#!/bin/bash
set -euo pipefail

# ==============================================================================
# Jetson kernel module builder
#
# Supports:
#   1) Native build on Jetson
#   2) Cross-compile on PC
#
# Features:
#   - Native Jetson: auto-discovers L4T version unless --kernel-version is given
#   - Cross-compile: requires --kernel-version
#   - Builds multiple modules from a modules.txt file
#   - Uses explicit release lookup for both public sources and toolchain
# ==============================================================================

# Colors for formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Formatting helpers
# ------------------------------------------------------------------------------
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
  $0 [--kernel-version VERSION] [--modules-file FILE]

Options:
  --kernel-version VERSION   Target L4T version (example: 36.4.3)
  --modules-file FILE        Module definition file (default: modules.txt)
  -h, --help                 Show this help

Behavior:
  Native Jetson:
    - defaults to discovered Jetson L4T version
    - can be overridden with --kernel-version

  Cross-compile on PC:
    - requires --kernel-version

Module file format:
  One module per line:
    module_name|config_symbol|module_dir

  Example:
    gs_usb|CONFIG_CAN_GS_USB|drivers/net/can/usb
    peak_usb|CONFIG_CAN_PEAK_USB|drivers/net/can/usb

Notes:
  - Lines starting with # are ignored
  - Blank lines are ignored
EOF
}

# ------------------------------------------------------------------------------
# Globals / defaults
# ------------------------------------------------------------------------------
ARCHITECTURE="$(uname -m)"
IS_ARM64=0
if [[ "$ARCHITECTURE" == "aarch64" || "$ARCHITECTURE" == "arm64" ]]; then
    IS_ARM64=1
fi

KERNEL_VERSION=""
MODULES_FILE="modules.txt"
SCRIPT_DIR="$(pwd)"

# Resolved later by lookup
NVIDIA_RELEASE_PATH=""
PUBLIC_SOURCES_URL=""
TOOLCHAIN_URL=""
TOOLCHAIN_ARCHIVE_NAME="aarch64--glibc--stable-2022.08-1.tar.bz2"
TOOLCHAIN_DIR_NAME="aarch64--glibc--stable-2022.08-1"

# Build paths resolved later
SRC_PATH=""
OUT_PATH=""
BUILD_ROOT=""
MODULE_INSTALL_BASE=""
TARGET_UNAME_R=""

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-version)
            if [[ $# -lt 2 ]]; then
                print_error "--kernel-version requires a value"
                exit 1
            fi
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --modules-file)
            if [[ $# -lt 2 ]]; then
                print_error "--modules-file requires a value"
                exit 1
            fi
            MODULES_FILE="$2"
            shift 2
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

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
discover_l4t_version() {
    # Preferred source on Jetson
    if [[ -f /etc/nv_tegra_release ]]; then
        sed -n 's/.*R\([0-9]\+\) (release), REVISION: \([0-9]\+\)\.\([0-9]\+\).*/\1.\2.\3/p' /etc/nv_tegra_release | head -n1
        return 0
    fi

    return 1
}

validate_kernel_version_format() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Invalid kernel/L4T version format: $version"
        print_error "Expected format: MAJOR.MINOR.PATCH (example: 36.4.3)"
        exit 1
    fi
}

resolve_release_info() {
    local version="$1"

    # Explicit mapping is safer than generating URLs blindly.
    case "$version" in
        36.4.3)
            NVIDIA_RELEASE_PATH="r36_release_v4.3"
            PUBLIC_SOURCES_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2"
            TOOLCHAIN_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2"
            ;;
        36.4.4)
            NVIDIA_RELEASE_PATH="r36_release_v4.4"
            PUBLIC_SOURCES_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.4/sources/public_sources.tbz2"
            TOOLCHAIN_URL="https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2"
            ;;
        *)
            print_error "Unsupported kernel/L4T version: $version"
            print_error "Add it to resolve_release_info() after verifying the NVIDIA public sources and toolchain paths."
            exit 1
            ;;
    esac
}

check_url_exists() {
    local url="$1"
    wget --spider -q "$url"
}

validate_modules_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        print_error "Modules file not found: $file"
        exit 1
    fi

    local line_no=0
    local valid_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        # Trim leading/trailing whitespace for simple emptiness check
        local trimmed
        trimmed="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" =~ ^# ]] && continue

        IFS='|' read -r module_name config_symbol module_dir extra <<< "$trimmed"

        if [[ -n "${extra:-}" || -z "${module_name:-}" || -z "${config_symbol:-}" || -z "${module_dir:-}" ]]; then
            print_error "Invalid modules file entry at line $line_no: $line"
            print_error "Expected format: module_name|config_symbol|module_dir"
            exit 1
        fi

        valid_count=$((valid_count + 1))
    done < "$file"

    if [[ $valid_count -eq 0 ]]; then
        print_error "No valid module entries found in $file"
        exit 1
    fi
}

enable_module_config() {
    local config_file="$1"
    local config_symbol="$2"

    if grep -q "^${config_symbol}=m$" "$config_file"; then
        print_info "${config_symbol} already set to module"
        return 0
    fi

    if grep -q "^${config_symbol}=y$" "$config_file"; then
        print_step "Changing ${config_symbol}=y to ${config_symbol}=m"
        sed -i "s/^${config_symbol}=y$/${config_symbol}=m/" "$config_file"
        return 0
    fi

    if grep -q "^# ${config_symbol} is not set$" "$config_file"; then
        print_step "Enabling ${config_symbol}=m"
        sed -i "s/^# ${config_symbol} is not set$/${config_symbol}=m/" "$config_file"
        return 0
    fi

    if grep -q "^${config_symbol}=" "$config_file"; then
        print_step "Updating ${config_symbol} to module"
        sed -i "s/^${config_symbol}=.*/${config_symbol}=m/" "$config_file"
        return 0
    fi

    print_step "Appending ${config_symbol}=m"
    echo "${config_symbol}=m" >> "$config_file"
}

install_dependencies() {
    print_header "INSTALLING DEPENDENCIES"

    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "Non-apt based system detected. Install dependencies manually."
        echo "Required packages:"
        echo "  build-essential bc libssl-dev flex bison wget git pv kmod ca-certificates libelf-dev"
        exit 1
    fi

    print_step "Updating package list..."
    sudo apt-get update -qq

    print_step "Installing required packages..."
    sudo apt-get install -qq -y \
        build-essential \
        bc \
        libssl-dev \
        flex \
        bison \
        wget \
        git \
        pv \
        kmod \
        ca-certificates \
        libelf-dev

    print_success "Dependencies installed"
}

prepare_kernel_config() {
    print_header "KERNEL CONFIGURATION"

    if [[ $IS_ARM64 -eq 1 ]]; then
        if [[ ! -f "$SCRIPT_DIR/config" ]]; then
            print_step "Generating kernel config from running Jetson..."
            if [[ -f /proc/config.gz ]]; then
                zcat /proc/config.gz > "$SCRIPT_DIR/config"
            else
                print_error "/proc/config.gz not found on this Jetson"
                print_error "Provide a config file manually at: $SCRIPT_DIR/config"
                exit 1
            fi
            print_success "Configuration generated: $SCRIPT_DIR/config"
        else
            print_info "Using existing config file: $SCRIPT_DIR/config"
        fi
    else
        if [[ ! -f "$SCRIPT_DIR/config" ]]; then
            print_error "Cross-compile mode requires a config file copied from target Jetson:"
            print_error "Expected: $SCRIPT_DIR/config"
            exit 1
        fi
        print_info "Using provided target config file: $SCRIPT_DIR/config"
    fi

    cp "$SCRIPT_DIR/config" "$OUT_PATH/.config"
    print_success "Copied config to $OUT_PATH/.config"

    print_step "Enabling requested module configs..."
    while IFS='|' read -r module_name config_symbol module_dir; do
        [[ -z "${module_name// }" ]] && continue
        [[ "$module_name" =~ ^[[:space:]]*# ]] && continue

        enable_module_config "$OUT_PATH/.config" "$config_symbol"
    done < "$SCRIPT_DIR/$MODULES_FILE"
}

download_and_extract_sources() {
    print_header "DOWNLOADING PUBLIC SOURCES"
    print_info "Resolved NVIDIA release path: $NVIDIA_RELEASE_PATH"
    print_info "Public sources URL: $PUBLIC_SOURCES_URL"

    if ! check_url_exists "$PUBLIC_SOURCES_URL"; then
        print_error "Public sources URL does not exist or is not reachable:"
        print_error "$PUBLIC_SOURCES_URL"
        exit 1
    fi

    if [[ ! -f "$SRC_PATH/public_sources.tbz2" ]]; then
        print_step "Downloading public_sources.tbz2..."
        wget --show-progress -q -O "$SRC_PATH/public_sources.tbz2" "$PUBLIC_SOURCES_URL"
        print_success "Downloaded public_sources.tbz2"
    else
        print_info "public_sources.tbz2 already exists, skipping download"
    fi

    print_header "EXTRACTING PUBLIC SOURCES"
    if [[ ! -d "$SRC_PATH/Linux_for_Tegra/source" ]]; then
        print_step "Extracting public_sources.tbz2..."
        (
            cd "$SRC_PATH"
            pv public_sources.tbz2 | tar xjf -
        )
        print_success "Extraction complete"
    else
        print_info "Linux_for_Tegra/source already extracted"
    fi

    if [[ ! -f "$SRC_PATH/Linux_for_Tegra/source/kernel_src.tbz2" ]]; then
        print_error "kernel_src.tbz2 not found after extracting public sources"
        exit 1
    fi

    if [[ ! -d "$SRC_PATH/Linux_for_Tegra/source/kernel/kernel-jammy-src" ]]; then
        print_step "Extracting kernel_src.tbz2..."
        (
            cd "$SRC_PATH/Linux_for_Tegra/source"
            tar xf kernel_src.tbz2
        )
        print_success "Kernel sources extracted"
    else
        print_info "kernel-jammy-src already extracted"
    fi
}

setup_toolchain_if_needed() {
    print_header "TOOLCHAIN CONFIGURATION"

    if [[ $IS_ARM64 -eq 1 ]]; then
        print_info "Native Jetson build: toolchain setup not required"
        return 0
    fi

    print_info "Toolchain URL: $TOOLCHAIN_URL"

    if ! check_url_exists "$TOOLCHAIN_URL"; then
        print_error "Toolchain URL does not exist or is not reachable:"
        print_error "$TOOLCHAIN_URL"
        exit 1
    fi

    if [[ ! -f "$SRC_PATH/$TOOLCHAIN_ARCHIVE_NAME" ]]; then
        print_step "Downloading cross-compilation toolchain..."
        wget --show-progress -q -O "$SRC_PATH/$TOOLCHAIN_ARCHIVE_NAME" "$TOOLCHAIN_URL"
        print_success "Toolchain downloaded"
    else
        print_info "Toolchain archive already exists"
    fi

    if [[ ! -d "$SRC_PATH/$TOOLCHAIN_DIR_NAME" ]]; then
        print_step "Extracting toolchain..."
        (
            cd "$SRC_PATH"
            tar xf "$TOOLCHAIN_ARCHIVE_NAME"
        )
        print_success "Toolchain extracted"
    else
        print_info "Toolchain already extracted"
    fi

    export CROSS_COMPILE="$SRC_PATH/$TOOLCHAIN_DIR_NAME/bin/aarch64-buildroot-linux-gnu-"

    if [[ ! -x "${CROSS_COMPILE}gcc" ]]; then
        print_error "Cross compiler not found at expected path: ${CROSS_COMPILE}gcc"
        exit 1
    fi

    print_success "Toolchain configured: $CROSS_COMPILE"
}

prepare_build_tree() {
    print_header "INITIAL SETUP"

    mkdir -p "$SCRIPT_DIR/$KERNEL_VERSION"
    cd "$SCRIPT_DIR/$KERNEL_VERSION"

    SRC_PATH="$PWD"
    OUT_PATH="$SRC_PATH/kernel_out"
    mkdir -p "$OUT_PATH"

    print_info "Script directory: $SCRIPT_DIR"
    print_info "Build root: $SRC_PATH"
    print_info "Output path: $OUT_PATH"
    print_info "Target L4T version: $KERNEL_VERSION"

    if [[ $IS_ARM64 -eq 1 ]]; then
        TARGET_UNAME_R="$(uname -r)"
        MODULE_INSTALL_BASE="/lib/modules/$TARGET_UNAME_R/kernel"
    else
        TARGET_UNAME_R="<target-jetson-uname-r>"
        MODULE_INSTALL_BASE="/lib/modules/$TARGET_UNAME_R/kernel"
    fi
}

run_modules_prepare() {
    print_header "PREPARING BUILD ENVIRONMENT"

    local kernel_src_dir="$SRC_PATH/Linux_for_Tegra/source/kernel/kernel-jammy-src"
    cd "$kernel_src_dir"

    if [[ $IS_ARM64 -eq 1 ]]; then
        make O="$OUT_PATH" modules_prepare |& tee "$OUT_PATH/prepare.log"
    else
        make O="$OUT_PATH" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare |& tee "$OUT_PATH/prepare.log"
    fi

    print_success "modules_prepare completed"
}

build_modules() {
    print_header "MODULE COMPILATION"

    local kernel_src_dir="$SRC_PATH/Linux_for_Tegra/source/kernel/kernel-jammy-src"
    cd "$kernel_src_dir"

    : > "$OUT_PATH/build.log"

    while IFS='|' read -r module_name config_symbol module_dir; do
        [[ -z "${module_name// }" ]] && continue
        [[ "$module_name" =~ ^[[:space:]]*# ]] && continue

        print_step "Compiling module: $module_name"
        print_info " - Config: $config_symbol"
        print_info " - Directory: $module_dir"

        if [[ $IS_ARM64 -eq 1 ]]; then
            make O="$OUT_PATH" M="$module_dir" modules |& tee -a "$OUT_PATH/build.log"
        else
            make O="$OUT_PATH" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" M="$module_dir" modules |& tee -a "$OUT_PATH/build.log"
        fi
    done < "$SCRIPT_DIR/$MODULES_FILE"

    print_success "All requested modules compiled"
    print_info "Preparation log: $OUT_PATH/prepare.log"
    print_info "Build log: $OUT_PATH/build.log"
}

install_or_export_modules() {
    print_header "INSTALLATION / POST-PROCESSING"

    while IFS='|' read -r module_name config_symbol module_dir; do
        [[ -z "${module_name// }" ]] && continue
        [[ "$module_name" =~ ^[[:space:]]*# ]] && continue

        local module_source_path="$OUT_PATH/$module_dir/$module_name.ko"
        local module_install_path="$MODULE_INSTALL_BASE/${module_dir#drivers/}"

        if [[ ! -f "$module_source_path" ]]; then
            print_error "Built module not found: $module_source_path"
            exit 1
        fi

        if [[ $IS_ARM64 -eq 1 ]]; then
            print_step "Installing $module_name to Jetson"
            sudo mkdir -p "$module_install_path"
            sudo cp -v "$module_source_path" "$module_install_path/"

            if ! grep -q "^$module_name$" /etc/modules; then
                echo "$module_name" | sudo tee -a /etc/modules >/dev/null
                print_success "$module_name added to /etc/modules"
            else
                print_info "$module_name already present in /etc/modules"
            fi
        else
            print_step "Copying $module_name.ko to script directory"
            cp -v "$module_source_path" "$SCRIPT_DIR/"
            print_success "Exported: $SCRIPT_DIR/$module_name.ko"
        fi
    done < "$SCRIPT_DIR/$MODULES_FILE"

    if [[ $IS_ARM64 -eq 1 ]]; then
        print_step "Updating module dependencies..."
        sudo depmod -a
        print_success "Installation complete. Reboot required."
    else
        print_header "JETSON INSTALLATION INSTRUCTIONS"
        echo -e "Copy the generated .ko files to the target Jetson and install them under:"
        echo -e "  ${YELLOW}/lib/modules/<target-jetson-uname-r>/kernel/...${NC}"
        echo
        echo -e "Then run on the Jetson:"
        echo -e "  ${YELLOW}sudo cp <module>.ko /lib/modules/<target-jetson-uname-r>/kernel/<module-subdir>/${NC}"
        echo -e "  ${YELLOW}echo '<module>' | sudo tee -a /etc/modules${NC}"
        echo -e "  ${YELLOW}sudo depmod -a${NC}"
        echo -e "  ${YELLOW}sudo reboot${NC}"
    fi
}

# ------------------------------------------------------------------------------
# Main flow
# ------------------------------------------------------------------------------
print_header "INITIAL CHECK"
if [[ $IS_ARM64 -eq 1 ]]; then
    print_success "Running on ARM64 (Jetson - Native Mode)"
else
    print_info "Running on $ARCHITECTURE (Cross-Compile Mode)"
fi

print_header "KERNEL VERSION RESOLUTION"
if [[ $IS_ARM64 -eq 1 ]]; then
    if [[ -z "$KERNEL_VERSION" ]]; then
        print_step "Discovering Jetson L4T version..."
        if ! KERNEL_VERSION="$(discover_l4t_version)"; then
            print_error "Failed to discover Jetson L4T version automatically."
            print_error "Use --kernel-version VERSION"
            exit 1
        fi
        print_success "Discovered Jetson L4T version: $KERNEL_VERSION"
    else
        print_info "Using user-specified kernel version: $KERNEL_VERSION"
    fi
else
    if [[ -z "$KERNEL_VERSION" ]]; then
        print_error "Cross-compile mode requires --kernel-version"
        exit 1
    fi
    print_info "Using cross-compile target L4T version: $KERNEL_VERSION"
fi

validate_kernel_version_format "$KERNEL_VERSION"
resolve_release_info "$KERNEL_VERSION"

print_header "MODULE FILE CHECK"
print_info "Modules file: $MODULES_FILE"
validate_modules_file "$MODULES_FILE"
print_success "Modules file is valid"

install_dependencies
prepare_build_tree
prepare_kernel_config
download_and_extract_sources
setup_toolchain_if_needed
run_modules_prepare
build_modules
install_or_export_modules

print_header "PROCESS COMPLETED"