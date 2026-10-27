#!/bin/bash
# Script to install necessary tools for disk testing

set -e

echo "=== Disk Testing Tools Installer ==="
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: This script requires root privileges or sudo."
    exit 1
  fi
  SUDO="sudo"
else
  SUDO=""
fi

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v pacman >/dev/null 2>&1; then
  PKG_MGR="pacman"
else
  echo "Error: Unsupported package manager"
  exit 1
fi

echo "Detected package manager: $PKG_MGR"
echo ""

# Update package lists
echo "Updating package lists..."
case "$PKG_MGR" in
  apt)
    $SUDO apt-get update -qq
    ;;
  yum|dnf)
    $SUDO $PKG_MGR makecache -q || true
    ;;
  pacman)
    $SUDO pacman -Sy --noconfirm
    ;;
esac

# Install tools
echo "Installing disk testing tools..."
case "$PKG_MGR" in
  apt)
    $SUDO apt-get install -y smartmontools hdparm fio iotop nvme-cli util-linux coreutils
    ;;
  yum)
    $SUDO yum install -y smartmontools hdparm fio iotop nvme-cli util-linux
    ;;
  dnf)
    $SUDO dnf install -y smartmontools hdparm fio iotop nvme-cli util-linux
    ;;
  pacman)
    $SUDO pacman -S --noconfirm smartmontools hdparm fio iotop nvme-cli util-linux
    ;;
esac

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Installed tools:"
if command -v smartctl >/dev/null 2>&1; then
  echo "  - smartctl: $(smartctl --version | head -1)"
elif [ -x "/usr/sbin/smartctl" ]; then
  echo "  - smartctl: $(/usr/sbin/smartctl --version | head -1)"
elif [ -x "/sbin/smartctl" ]; then
  echo "  - smartctl: $(/sbin/smartctl --version | head -1)"
fi
if command -v hdparm >/dev/null 2>&1; then
  echo "  - hdparm: $(hdparm -V 2>&1 | head -1)"
elif [ -x "/usr/sbin/hdparm" ]; then
  echo "  - hdparm: $(/usr/sbin/hdparm -V 2>&1 | head -1)"
elif [ -x "/sbin/hdparm" ]; then
  echo "  - hdparm: $(/sbin/hdparm -V 2>&1 | head -1)"
fi
if command -v fio >/dev/null 2>&1; then
  echo "  - fio: $(fio --version | head -1)"
fi
if command -v nvme >/dev/null 2>&1; then
  echo "  - nvme-cli: $(nvme version 2>&1 | head -1)"
elif [ -x "/usr/sbin/nvme" ]; then
  echo "  - nvme-cli: $(/usr/sbin/nvme version 2>&1 | head -1)"
elif [ -x "/sbin/nvme" ]; then
  echo "  - nvme-cli: $(/sbin/nvme version 2>&1 | head -1)"
fi
if command -v iostat >/dev/null 2>&1; then
  echo "  - sysstat (iostat): $(iostat -V 2>&1 | head -1)"
fi

echo ""
echo "You can now run the test script: ./test-disks.sh /dev/sdX /dev/sdY"
