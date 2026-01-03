{
  flake,
  flakeAttr,
  diskMappings,
  extraSystemConfig ? "{}",
  writeEfiBootEntries ? false,
  rootMountPoint ? "/mnt",
  hostSystem ? builtins.currentSystem,
}:
let
  originalSystem = (builtins.getFlake "${flake}").nixosConfigurations."${flakeAttr}";
  lib = originalSystem.pkgs.lib;

  # Host pkgs for building host-native scripts (used in cross-VM mode)
  hostPkgs = import originalSystem.pkgs.path { system = hostSystem; };

  deviceName =
    name:
    if diskMappings ? ${name} then
      diskMappings.${name}
    else
      throw "No device passed for disk '${name}'. Pass `--disk ${name} /dev/name` via commandline";

  modifiedDisks = builtins.mapAttrs (
    name: value:
    let
      dev = deviceName name;
    in
    value
    // {
      device = dev;
      content = value.content // {
        device = dev;
      };
    }
  ) originalSystem.config.disko.devices.disk;

  # filter all nixos module internal attributes
  cleanedDisks = lib.filterAttrsRecursive (n: _: !lib.hasPrefix "_" n) modifiedDisks;

  diskoSystem = originalSystem.extendModules {
    modules = [
      {
        disko.rootMountPoint = rootMountPoint;
        disko.devices.disk = lib.mkVMOverride cleanedDisks;
      }
    ];
  };

  installSystem = originalSystem.extendModules {
    modules = [
      (
        { lib, ... }:
        {
          boot.loader.efi.canTouchEfiVariables = lib.mkVMOverride writeEfiBootEntries;
          boot.loader.grub.devices = lib.mkVMOverride (lib.attrValues diskMappings);
          imports = [
            ({ _file = "disko-install --system-config"; } // (builtins.fromJSON extraSystemConfig))
          ];
        }
      )
    ];
  };
  # Build host-native mount script for cross-VM mode
  # Uses host architecture binaries so it can run on the host after VM formatting
  hostMountScript = (diskoSystem.config.disko.devices._scripts { pkgs = hostPkgs; }).mountScript;
in
{
  installToplevel = installSystem.config.system.build.toplevel;
  closureInfo = installSystem.pkgs.closureInfo {
    rootPaths = [ installSystem.config.system.build.toplevel ];
  };
  inherit (diskoSystem.config.system.build) formatScript mountScript diskoScript;
  inherit hostMountScript;
}
