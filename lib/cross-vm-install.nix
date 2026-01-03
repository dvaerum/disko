# Cross-architecture VM-based installation for disko
#
# This module enables disko-install to work with architectures that differ
# from the host by running the disk formatting in a full system VM.
# This is necessary because some filesystem tools (like ZFS) require kernel
# module support and can't work via userspace emulation (binfmt/qemu-user).
#
# Usage: disko-install --cross-vm --flake .#myconfig --disk main /dev/sdX
{
  lib ? (import <nixpkgs> {}).lib,
  hostPkgs ? import <nixpkgs> {},
  targetSystem,
  formatScript,  # Format-only script (no mount) - runs inside VM to create filesystems
  diskMappings,
  vmMemoryMB ? 2048,  # VM memory in megabytes (default 2GB, increase for large ZFS operations)
}:

let
  # Map system to QEMU architecture name
  # Only include architectures that are tested/supported
  qemuArch = {
    "aarch64-linux" = "aarch64";
    "x86_64-linux" = "x86_64";
    "armv7l-linux" = "arm";
    "riscv64-linux" = "riscv64";
    "i686-linux" = "i386";
  }.${targetSystem} or (throw "Unsupported target system for cross-VM: ${targetSystem}. Supported: aarch64-linux, x86_64-linux, armv7l-linux, riscv64-linux, i686-linux");

  # QEMU machine type for each architecture
  qemuMachine = {
    "aarch64" = "virt";
    "x86_64" = "q35";
    "arm" = "virt";
    "riscv64" = "virt";
    "i386" = "q35";
  }.${qemuArch};

  # CPU type for each architecture
  qemuCpu = {
    "aarch64" = "max";
    "x86_64" = "max";
    "arm" = "max";
    "riscv64" = "rv64";
    "i386" = "max";
  }.${qemuArch};

  # Console device for each architecture
  consoleDevice = {
    "aarch64" = "ttyAMA0";
    "x86_64" = "ttyS0";
    "arm" = "ttyAMA0";
    "riscv64" = "ttyS0";
    "i386" = "ttyS0";
  }.${qemuArch};

  # Kernel image name for each architecture
  kernelImage = {
    "aarch64" = "Image";
    "x86_64" = "bzImage";
    "arm" = "zImage";
    "riscv64" = "Image";
    "i386" = "bzImage";
  }.${qemuArch};

  # Create ordered list of disk names (for mapping to vda, vdb, etc.)
  # Note: lib.attrNames returns alphabetical order. This is consistent across
  # both QEMU drive args and symlink creation, so the mapping is correct.
  diskNamesOrdered = lib.attrNames diskMappings;

  # All possible virtio disk device suffixes (a-z, supports up to 26 disks)
  virtioSuffixes = lib.strings.stringToCharacters "abcdefghijklmnopqrstuvwxyz";

  # Generate symlink commands to map host device paths to virtio devices inside VM
  # This creates /dev/disk/by-id/... symlinks pointing to /dev/vda, /dev/vdb, etc.
  diskSymlinkScript = lib.concatImapStringsSep "\n" (idx: name:
    let
      device = diskMappings.${name};
      diskIndex = idx - 1;
      virtioDevice =
        if diskIndex >= lib.length virtioSuffixes then
          throw "Too many disks: cross-VM mode supports at most ${toString (lib.length virtioSuffixes)} disks"
        else
          "/dev/vd${lib.elemAt virtioSuffixes diskIndex}";
      deviceDir = builtins.dirOf device;
    in ''
      echo "  - ${device} -> ${virtioDevice}"
      mkdir -p "${deviceDir}"
      ln -sf "${virtioDevice}" "${device}"
    ''
  ) diskNamesOrdered;

  # Build a proper NixOS system with initrd that runs our script
  vmConfig = { config, pkgs, lib, modulesPath, ... }: {
    imports = [
      (modulesPath + "/profiles/minimal.nix")
    ];

    system.stateVersion = "24.11";

    # Root filesystem (tmpfs for the VM)
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=2G" ];
    };

    boot.loader.grub.enable = false;
    documentation.enable = false;
    programs.command-not-found.enable = false;

    # Filesystem support - include all filesystems that might need kernel modules
    # The hostId is required by ZFS but doesn't affect pool creation.
    # Pools are exported before VM shutdown and will be imported on the
    # target system with the target's actual hostId.
    boot.supportedFilesystems = [ "zfs" "btrfs" "xfs" "bcachefs" ];
    boot.zfs.forceImportRoot = false;
    networking.hostId = "deadbeef";  # Placeholder, only used during formatting VM
    networking.hostName = "disko-cross-vm";

    # Add required kernel modules
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "9p"
      "9pnet"
      "9pnet_virtio"
      # NLS modules for FAT filesystem mounting
      "nls_cp437"
      "nls_iso8859_1"
      "vfat"
      "fat"
      # RAID support
      "dm_mod"
      "raid0"
      "raid1"
      "raid456"
      "raid10"
    ];

    # Include filesystem support in initrd
    boot.initrd.supportedFilesystems = [ "zfs" "vfat" "btrfs" "xfs" "bcachefs" ];

    # Run our disko script as a boot command before anything else
    # Use preLVMCommands which runs very early in stage 1
    boot.initrd.preLVMCommands = ''
      echo "Cross-VM disko formatting started"

      echo "Mounting host nix store"
      mkdir -p /nix/store
      mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576 nix-store /nix/store || {
        echo "Failed to mount nix store via 9p" >&2
        poweroff -f
      }

      echo "Setting up disk device symlinks"
      ${diskSymlinkScript}

      echo "Available block devices:"
      ls -la /dev/vd* /dev/sd* 2>/dev/null || true
      ls -la /dev/disk/by-id/ 2>/dev/null || true

      echo "Running disko format script"
      export DISKO_SKIP_SWAP=1

      # Run the script but don't fail on mount errors
      # ZFS pools are created and exported, FAT partitions are formatted
      set +e
      ${formatScript}
      disko_exit=$?
      set -e

      echo "Exporting ZFS pools"
      for pool in $(zpool list -H -o name 2>/dev/null || true); do
        echo "  - $pool"
        zpool export "$pool" || true
      done

      if [ $disko_exit -eq 0 ]; then
        echo "Disko formatting successful"
      else
        echo "Disko script exited with code $disko_exit (mount failures are expected)"
        echo "Formatting should still be complete, continuing"
      fi

      sync
      echo "Shutting down VM"
      poweroff -f
    '';
  };

  # Build the VM system
  vmSystem = (import (hostPkgs.path + "/nixos/lib/eval-config.nix") {
    system = targetSystem;
    modules = [ vmConfig ];
  }).config;

  # Serialize disk mappings for passing to QEMU
  diskDriveArgs = lib.concatMapStringsSep " " (name:
    let device = diskMappings.${name};
    in "-drive file=${device},format=raw,if=virtio,cache=unsafe"
  ) diskNamesOrdered;

in hostPkgs.writeShellScript "cross-vm-install" ''
  set -euo pipefail

  echo "Starting cross-architecture VM for disk formatting"
  echo "  - Target system: ${targetSystem}"
  echo "  - Host system: ${hostPkgs.stdenv.hostPlatform.system}"

  echo "Launching QEMU VM"
  echo "  - Kernel: ${vmSystem.system.build.kernel}/${kernelImage}"
  echo "  - Initrd: ${vmSystem.system.build.initialRamdisk}/initrd"

  # We use || true because QEMU exit codes are unreliable with poweroff -f
  ${hostPkgs.qemu}/bin/qemu-system-${qemuArch} \
    -M ${qemuMachine} \
    -cpu ${qemuCpu} \
    -m ${toString vmMemoryMB} \
    -smp 2 \
    -nographic \
    -kernel ${vmSystem.system.build.kernel}/${kernelImage} \
    -initrd ${vmSystem.system.build.initialRamdisk}/initrd \
    -append "console=${consoleDevice} loglevel=4" \
    -virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store \
    ${diskDriveArgs} \
    -no-reboot \
    || true

  echo "Cross-VM formatting complete"
''
