#!/bin/bash
# Script to perform disk tests - speed and stability
# Args: mounted partition files like /dev/sdb1

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Disk Speed & Stability Tester ===${NC}"
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo -e "${RED}Error: This script requires root privileges for most tests.${NC}"
    echo "Please run with sudo or as root."
    exit 1
  fi
  SUDO="sudo"
else
  SUDO=""
fi

# Function to find tool in common locations
find_tool() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    command -v "$cmd"
    return 0
  elif [ -x "/usr/sbin/$cmd" ]; then
    echo "/usr/sbin/$cmd"
    return 0
  elif [ -x "/sbin/$cmd" ]; then
    echo "/sbin/$cmd"
    return 0
  elif [ -x "/usr/bin/$cmd" ]; then
    echo "/usr/bin/$cmd"
    return 0
  elif [ -x "/bin/$cmd" ]; then
    echo "/bin/$cmd"
    return 0
  fi
  return 1
}

SMARTCTL=$(find_tool smartctl || true)
HDPARM=$(find_tool hdparm || true)
NVME=$(find_tool nvme || true)
FIO=$(find_tool fio || true)
IOSTAT=$(find_tool iostat || true)

# Check if partitions are provided
if [ $# -eq 0 ]; then
  echo -e "${RED}Error: No partitions specified${NC}"
  echo "Usage: $0 /dev/sdX1 [ /dev/sdY1 ... ]"
  echo ""
  echo "Example: $0 /dev/sdb1"
  exit 1
fi

# Helper: print a line to screen
say() {
  echo -e "$1"
}

# Helper: run a command once, show output on screen
run_cmd() {
  local label="$1"; shift
  say "${BLUE}${label}${NC}"
  "$@" 2>&1 || true
  echo ""
}

# Function to check if a partition's disk contains the OS root (/)
is_os_partition() {
  local part="$1"
  local base_part=$(basename "$part")
  local disk=$(echo "$base_part" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
  
  local root_src=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [ -z "$root_src" ]; then
    return 1
  fi
  
  if [[ "$root_src" == "$part" ]]; then
    return 0
  fi
  
  local root_base=$(basename "$root_src" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
  if [[ "$root_base" == "$disk" ]]; then
    return 0
  fi
  
  return 1
}

# Function to get mount point of a partition
get_mount_point() {
  local part="$1"
  local mnt=$(findmnt -no TARGET "$part" 2>/dev/null || true)
  if [ -n "$mnt" ] && [ "$mnt" != "-" ]; then
    echo "$mnt"
    return 0
  fi
  echo ""
  return 1
}

# Function to create temp dir
# Log messages go to stderr so they don't pollute the captured path on stdout.
create_temp_dir() {
  local part="$1"
  local tmpdir=""
  
  say "${BLUE}[LOG] Setting up temporary directory for testing...${NC}" >&2
  
  if is_os_partition "$part"; then
    say "${YELLOW}  Partition $part is on OS disk/root related${NC}" >&2
    local user_home="${HOME:-/home/$(whoami)}"
    mkdir -p "$user_home" 2>/dev/null || true
    tmpdir="$user_home/test-disks-tmp"
    say "${BLUE}[LOG] Using user home: $user_home${NC}" >&2
  else
    local mnt=$(get_mount_point "$part")
    if [ -n "$mnt" ]; then
      say "${GREEN}  Partition $part mounted at $mnt${NC}" >&2
      tmpdir="$mnt/test-disks-tmp"
      say "${BLUE}[LOG] Using mount point: $mnt${NC}" >&2
    else
      say "${RED}[LOG] Partition $part is not mounted${NC}" >&2
      return 1
    fi
  fi
  
  # Create tmp folder if missing
  if [ -d "$tmpdir" ]; then
    say "${YELLOW}[LOG] Temporary directory already exists: $tmpdir (will clean it up after test)${NC}" >&2
  else
    mkdir -p "$tmpdir" 2>/dev/null || true
    if [ -d "$tmpdir" ]; then
      say "${GREEN}[LOG] Created temporary directory: $tmpdir${NC}" >&2
    else
      say "${RED}[LOG] Failed to create temporary directory: $tmpdir${NC}" >&2
      return 1
    fi
  fi
  
  echo "$tmpdir"
}

# Function to cleanup
cleanup_temp() {
  local tmpdir="$1"
  if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
    say "${BLUE}[LOG] Cleaning up temporary directory after test...${NC}"
    rm -rf "$tmpdir" 2>/dev/null || true
    if [ ! -d "$tmpdir" ]; then
      say "${GREEN}[LOG] Cleanup complete - removed $tmpdir${NC}"
    else
      say "${YELLOW}[LOG] Cleanup may be incomplete - $tmpdir still exists${NC}"
    fi
  fi
}

# Create user temp dir if needed
mkdir -p /home/vadim/tmp 2>/dev/null || true
say "${GREEN}[LOG] Ensured /home/vadim/tmp directory exists${NC}"

# Process each partition
for PART in "$@"; do
  echo ""
  say "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  say "${BLUE}Testing Partition: $PART${NC}"
  say "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  
  # Check if partition exists
  if [ ! -b "$PART" ]; then
    say "${RED}Error: $PART is not a block device${NC}"
    continue
  fi
  
  # Check if partition is mounted
  MOUNTPOINT=$(get_mount_point "$PART")
  if [ -z "$MOUNTPOINT" ]; then
    say "${RED}Error: $PART is not mounted. This script requires mounted partitions.${NC}"
    continue
  fi
  
  say "${GREEN}[LOG] Partition $PART is mounted at $MOUNTPOINT${NC}"
  
  # Get device info
  DISK=$(basename "$PART" | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
  DEVICE="/dev/$DISK"
  
  say "${YELLOW}Device Information:${NC}"
  lsblk_out=$($SUDO lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,ROTA "$DEVICE" 2>/dev/null || lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,ROTA "$DEVICE") || true
  echo "$lsblk_out"
  echo ""
  part_out=$($SUDO lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE "$PART" 2>/dev/null || lsblk -o NAME,FSTYPE,MOUNTPOINT,SIZE "$PART") || true
  echo "$part_out"
  echo ""
  
  # Check if it's an SSD (ROTA=0) or HDD (ROTA=1)
  ROTA=$(cat /sys/block/$DISK/queue/rotational 2>/dev/null || echo "unknown")
  if [ "$ROTA" = "0" ]; then
    say "${GREEN}  Type: SSD (rotational=0)${NC}"
  elif [ "$ROTA" = "1" ]; then
    say "${YELLOW}  Type: HDD (rotational=1)${NC}"
  else
    say "${YELLOW}  Type: Unknown${NC}"
  fi
  echo ""
  
  # Create temp directory
  WORKDIR=$(create_temp_dir "$PART") || {
    say "${RED}Failed to setup temp directory for $PART. Skipping.${NC}"
    continue
  }
  
  say "${GREEN}[LOG] Using temp directory: $WORKDIR${NC}"
  
  # Cleanup trap
  trap "cleanup_temp '$WORKDIR'" EXIT INT TERM
  
  echo ""
  say "${YELLOW}=== STABILITY TESTS ===${NC}"
  echo ""
  
  # SMART Health Check (on whole disk)
  if [ -n "$SMARTCTL" ]; then
    run_cmd "1. SMART Health Status (disk $DEVICE)" $SUDO "$SMARTCTL" -H "$DEVICE"
    run_cmd "2. SMART Critical Attributes (disk $DEVICE)" $SUDO "$SMARTCTL" -A "$DEVICE"
    run_cmd "3. SMART Self-Test Log (recent, disk $DEVICE)" $SUDO "$SMARTCTL" -l selftest "$DEVICE"
  else
    say "${YELLOW}smartctl not found. Skipping SMART tests.${NC}"
    say "Run install-tools.sh first to install smartmontools."
    echo ""
  fi
  
  # Kernel errors
  run_cmd "4. Recent Kernel Errors (disk $DISK)" bash -c "dmesg | grep -i '$DISK' | tail -10 || echo '  No recent errors found in dmesg'"
  
  echo ""
  say "${YELLOW}=== SPEED TESTS ===${NC}"
  echo ""
  
  # hdparm cached/buffered tests (on whole disk)
  if [ -n "$HDPARM" ]; then
    run_cmd "5. hdparm Cache & Read Tests (disk $DEVICE)" $SUDO "$HDPARM" -Tt "$DEVICE"
  else
    say "${YELLOW}hdparm not found. Skipping hdparm tests.${NC}"
    echo ""
  fi
  
  # dd read test (on whole disk)
  say "${BLUE}6. Direct Read Test (dd, disk $DEVICE)${NC}"
  say "  Testing 1GB sequential read from $DEVICE..."
  if [ "$ROTA" = "1" ]; then
    COUNT=512
  else
    COUNT=1024
  fi
  dd_out=$($SUDO dd if="$DEVICE" of=/dev/null bs=1M count=$COUNT iflag=direct status=progress 2>&1 | tail -3) || true
  echo "$dd_out"
  echo ""
  
  # fio test - write to temp location on mounted filesystem
  if [ -n "$FIO" ]; then
    say "${BLUE}7. fio Sequential I/O Tests (on mounted filesystem at $MOUNTPOINT)${NC}"
    TESTFILE="$WORKDIR/testfile"
    
    say "${BLUE}[LOG] Checking space for fio tests in $WORKDIR${NC}"
    
    NEEDED_MB=2048
    say "${BLUE}[LOG] Running: df -k \"$WORKDIR\"${NC}"
    df -k "$WORKDIR" 2>&1 | tail -1
    avail_kb=$(df -k "$WORKDIR" 2>/dev/null | tail -1 | awk '{print $4}')
    say "${BLUE}[LOG] Extracted avail_kb='$avail_kb'${NC}"
    if [ -n "$avail_kb" ] && [ "$avail_kb" != "-" ]; then
      avail_mb=$((avail_kb / 1024))
      say "${BLUE}[LOG] Available space in $WORKDIR: ${avail_mb}MB (need ${NEEDED_MB}MB)${NC}"
    fi
    
    needed_kb=$((NEEDED_MB * 1024))
    if [ -n "$avail_kb" ] && [ "$avail_kb" != "-" ] && [ "$avail_kb" -ge "$needed_kb" ] 2>/dev/null; then
      say "  Sequential Read Test (1GB, direct I/O)..."
      say "${BLUE}[LOG] Creating test file for read test: $TESTFILE${NC}"
      fio_read_out=$($SUDO "$FIO" --name=seqread --filename="$TESTFILE" --rw=read --bs=1M --size=1G --numjobs=1 --direct=1 --runtime=30 --time_based=0 --group_reporting 2>&1 | grep -E '(READ|bw=|IOPS=)') || true
      echo "$fio_read_out"
      echo ""
      if [ -f "$TESTFILE" ]; then
        say "${BLUE}[LOG] Test file exists after read test: $TESTFILE ($(ls -lh $TESTFILE 2>/dev/null | awk '{print $5}'))${NC}"
      fi
      
      say "  Sequential Write Test (1GB, direct I/O)..."
      if [ -f "$TESTFILE" ]; then
        rm -f "$TESTFILE"
        say "${BLUE}[LOG] Cleaned up previous test file before write test: $TESTFILE${NC}"
      fi
      say "${BLUE}[LOG] Creating test file for write test: $TESTFILE${NC}"
      fio_write_out=$($SUDO "$FIO" --name=seqwrite --filename="$TESTFILE" --rw=write --bs=1M --size=1G --numjobs=1 --direct=1 --runtime=30 --time_based=0 --group_reporting 2>&1 | grep -E '(WRITE|bw=|IOPS=)') || true
      echo "$fio_write_out"
      echo ""
      
      if [ -f "$TESTFILE" ]; then
        say "${BLUE}[LOG] Test file exists after write test: $TESTFILE ($(ls -lh $TESTFILE 2>/dev/null | awk '{print $5}'))${NC}"
        rm -f "$TESTFILE"
        say "${BLUE}[LOG] Cleaned up test file after write test: $TESTFILE${NC}"
      else
        say "${BLUE}[LOG] Test file already cleaned up or not created: $TESTFILE${NC}"
      fi
    else
      say "${YELLOW}  Not enough space in temp directory for fio tests (need ~2GB)${NC}"
      say "  Skipping fio tests"
      echo ""
    fi
  else
    say "${YELLOW}fio not found. Skipping fio tests.${NC}"
    echo ""
  fi
  
  # Cleanup
  cleanup_temp "$WORKDIR"
  trap - EXIT INT TERM
  
  echo ""
  say "${GREEN}=== Tests completed for partition $PART ===${NC}"
  echo ""
done

echo -e "${BLUE}All tests finished!${NC}"
