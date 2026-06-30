# L4T Kernel Builder

## ⚡ Quick Start

This script supports:

- ✅ Native compilation on Jetson  
- 🔁 Cross-compilation on PC  
- 📦 Building multiple kernel modules via `modules.txt`  

---

## 📄 Module Configuration

Before running, create a `modules.txt` file:

For example: CAN kernels

```txt
# module_name|config_symbol|module_dir

gs_usb|CONFIG_CAN_GS_USB|drivers/net/can/usb
peak_usb|CONFIG_CAN_PEAK_USB|drivers/net/can/usb
```

- `module_name` → output `.ko` name  
- `config_symbol` → kernel config to enable  
- `module_dir` → path inside kernel source  

---

## 📦 Native Compilation (on Jetson)

### 1. Clone the repository and run the build script

```bash
git clone https://github.com/pairlab/jetson-gs_usb-kernel-builder.git
cd jetson-gs_usb-kernel-builder

./jetson-gs_usb-kernel-builder.sh
```

### ✔️ Behavior

- Automatically detects Jetson L4T version  
- Generates kernel config from `/proc/config.gz`  
- Builds all modules listed in `modules.txt`  
- Installs modules directly to system  
- Adds them to `/etc/modules`  
- Runs `depmod`  

### 📌 Optional: Specify kernel version manually

```bash
./jetson-gs_usb-kernel-builder.sh --kernel-version 36.4.3
```

---

## 🟢 Native-headers mode (L4T R38 / Jetson Thor and any kernel with installed headers)

On newer JetPack/L4T releases (e.g. **R38 / Thor, kernel 6.8.x**) the matching
`linux-headers` package is already installed and `/lib/modules/$(uname -r)/build`
points at a configured, prepared kernel build tree. In that case the script builds
the modules **out-of-tree against the installed headers** instead of downloading the
full NVIDIA public sources + toolchain:

```bash
./jetson-kernel-builder.sh --modules-file can_modules.txt
```

### ✔️ Behavior

- Auto-detected when running on a Jetson and `/lib/modules/$(uname -r)/build` exists
- Derives the matching upstream stable tag from `uname -r` (e.g. `6.8.12` → `v6.8.12`)
- The headers package ships the build infrastructure but strips driver `.c/.h` files,
  so those are fetched from `gregkh/linux` at that tag (resolving `#include` headers
  recursively)
- Forces the requested `CONFIG_*` symbols to `=m` on the make line (they are usually
  "not set" in the running kernel `.config`)
- Builds into `./can_build/`, installs the `.ko` files under
  `/lib/modules/$(uname -r)/kernel/<module_dir>`, adds them to `/etc/modules`, runs `depmod`
- Pass `--kernel-version VERSION` to force the public-sources download path instead

---

## 🔁 Cross-Compilation Workflow (Jetson → Host → Jetson)

### 1. On Jetson: Export kernel config

```bash
zcat /proc/config.gz > config
```

### 2. Copy config file to your host machine

```bash
scp config user@host:/path/to/jetson-gs_usb-kernel-builder/
```

---

### 3. On host: Clone the repository and run the build script

```bash
git clone https://github.com/pairlab/jetson-gs_usb-kernel-builder.git
cd jetson-gs_usb-kernel-builder

./jetson-gs_usb-kernel-builder.sh --kernel-version 36.4.3
```

### ✔️ Behavior

- Requires `--kernel-version` on PC  
- Downloads matching:
  - public kernel sources  
  - cross-compilation toolchain  
- Builds all modules from `modules.txt`  
- Outputs `.ko` files to current directory  

---

### 4. Copy modules back to Jetson

```bash
scp *.ko user@jetson:/home/user/
```

---

### 5. Install modules on Jetson

```bash
sudo mkdir -p /lib/modules/$(uname -r)/kernel/<module-subdir>/
sudo cp *.ko /lib/modules/$(uname -r)/kernel/<module-subdir>/

echo "<module_name>" | sudo tee -a /etc/modules

sudo depmod -a
sudo reboot
```

---

## ⚙️ Script Options

```bash
./jetson-gs_usb-kernel-builder.sh [OPTIONS]

Options:
  --kernel-version VERSION   Target L4T version (required for cross-compile)
  --modules-file FILE        Module definition file (default: modules.txt)
  -h, --help                 Show help
```

---

## 📦 Supported Kernel Versions

This script uses a **lookup table** for NVIDIA releases to ensure the correct:

- public source package  
- toolchain version  

Currently supported:

- `36.4.3`  
- `36.4.4`  

To add support for a new version:

- Update `resolve_release_info()` in the script  
- Verify URLs from NVIDIA Jetson Linux resources  

---

## ⚠️ Notes & Limitations

- Cross-compilation requires a valid `config` from the target Jetson  
- Kernel version refers to the **L4T version** (for example `36.4.3`), not `uname -r`  
- Modules are installed automatically only in native mode  
- Cross-compiled modules must be manually copied to Jetson  

---

## 💡 Tips

- Keep multiple `modules.txt` files for different projects or devices  
- Version-control your module list for reproducibility  
- Use native mode for quick iteration, and cross-compile for CI or faster builds  
