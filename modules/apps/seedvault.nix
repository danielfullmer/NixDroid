{ config, pkgs, apks, lib, ... }:

with lib;
let
  cfg = config.apps.seedvault;
in
{
  options = {
    apps.seedvault.enable = mkEnableOption "Seedvault (backup)";
  };

  config = mkMerge [
  {
    # In order to switch to using this if it's not set on the first boot, run these:
    # $ bmgr list transports
    # $ bmgr transport com.stevesoltys.seedvault.transport.ConfigurableBackupTransport

    # Set as default
    resources."frameworks/base/packages/SettingsProvider".def_backup_enabled = true;
    resources."frameworks/base/packages/SettingsProvider".def_backup_transport = "com.stevesoltys.seedvault.transport.ConfigurableBackupTransport";
  }
  (mkIf (cfg.enable && config.androidVersion >= 11) {
    # For android 11, just use the source tree from upstream, and have soong build it
    source.dirs."robotnix/seedvault".src = pkgs.fetchFromGitHub {
      owner = "stevesoltys";
      repo = "seedvault";
      rev = "a1b68df9238c69847a9767cfd4186b6a8d9689bd";
      sha256 = "0c4l431dyb9zych3n1d8wfq0ybn1ilaj1cjvrjs196ximps09fg0";
    };

    product.additionalProductPackages = [ "Seedvault" ];
  })
  (mkIf (cfg.enable && config.androidVersion == 10) {
    # For android 10, use the version built natively in nix using gradle2nix.
    apps.prebuilt.Seedvault = {
      apk = apks.seedvault_10;
      packageName = "com.stevesoltys.seedvault";
      certificate = "platform"; # Needs this certificate to use MANAGE_DOCUMENTS permission
      privileged = true;
      privappPermissions = [ "BACKUP" "MANAGE_USB" "WRITE_SECURE_SETTINGS" "INSTALL_PACKAGES" ];
    };

    etc."sysconfig/com.stevesoltys.seedvault.xml".text = ''
      <?xml version="1.0" encoding="utf-8"?>
      <config>
        <backup-transport-whitelisted-service
          service="com.stevesoltys.seedvault/.transport.ConfigurableBackupTransportService"/>
      </config>
    '';
  })
  ];
}
