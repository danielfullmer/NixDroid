{ config, pkgs, lib, ... }:

with lib;
let
  otaTools = config.build.otaTools;

  avbFlags = {
    verity_only = [
      "--replace_verity_public_key $KEYSDIR/verity_key.pub"
      "--replace_verity_private_key $KEYSDIR/verity"
      "--replace_verity_keyid $KEYSDIR/verity.x509.pem"
    ];
    vbmeta_simple = [ "--avb_vbmeta_key $KEYSDIR/avb.pem" "--avb_vbmeta_algorithm SHA256_RSA2048" ];
    vbmeta_chained = [
      "--avb_vbmeta_key $KEYSDIR/avb.pem"
      "--avb_vbmeta_algorithm SHA256_RSA2048"
      "--avb_system_key $KEYSDIR/avb.pem"
      "--avb_system_algorithm SHA256_RSA2048"
    ] ++ optionals (config.androidVersion >= 10) [
      "--avb_system_other_key $KEYSDIR/avb.pem"
      "--avb_system_other_algorithm SHA256_RSA2048"
    ];
  }.${config.avbMode};

  wrapScript = { commands, keysDir ? "" }: ''
    export PATH=${otaTools}/bin:$PATH
    export EXT2FS_NO_MTAB_OK=yes

    # build-tools releasetools/common.py hilariously tries to modify the
    # permissions of the source file in ZipWrite. Since signing uses this
    # function with a key, we need to make a temporary copy of our keys so the
    # sandbox doesn't complain if it doesn't have permissions to do so.
    export KEYSDIR=${keysDir}
    if [[ "$KEYSDIR" ]]; then
      if [[ ! -d "$KEYSDIR" ]]; then
        echo 'Missing KEYSDIR directory, did you use "--option extra-sandbox-paths /keys=..." ?'
        exit 1
      fi
      mkdir -p keys_copy
      cp -r $KEYSDIR/* keys_copy/
      KEYSDIR=$(pwd)/keys_copy
    fi

    ${commands}

    if [[ "$KEYSDIR" ]]; then rm -rf "$KEYSDIR"; fi
  '';

  runWrappedCommand = name: script: args: pkgs.runCommand "${config.device}-${name}-${config.buildNumber}.zip" {} (wrapScript {
    commands = script (args // {out="$out";});
    keysDir = optionalString config.signBuild "/keys/${config.device}";
  });

  signedTargetFilesScript = { targetFiles, out }: ''
  ( cd ${otaTools}; # Enter otaTools dir so relative paths are correct for finding original keys
    ${otaTools}/releasetools/sign_target_files_apks.py \
      -o -d $KEYSDIR ${toString avbFlags} \
      ${optionalString (config.androidVersion >= 10) "--key_mapping build/target/product/security/networkstack=$KEYSDIR/networkstack"} \
      ${concatMapStringsSep " " (k: "--extra_apks ${k}.apex=$KEYSDIR/${k} --extra_apex_payload_key ${k}.apex=$KEYSDIR/${k}.pem") config.apex.packageNames} \
      ${targetFiles} ${out}
  )
  '';
  otaScript = { targetFiles, prevTargetFiles ? null, out }: ''
    ${otaTools}/releasetools/ota_from_target_files.py  \
      --block \
      ${if config.signBuild
        then "-k $KEYSDIR/releasekey"
        else "-k ${config.source.dirs."build/make".src}/target/product/security/testkey"
      } \
      ${optionalString (prevTargetFiles != null) "-i ${prevTargetFiles}"} \
      ${optionalString config.retrofit "--retrofit_dynamic_partitions"} \
      ${targetFiles} ${out}
  '';
  imgScript = { targetFiles, out }: ''${otaTools}/releasetools/img_from_target_files.py ${targetFiles} ${out}'';
  factoryImgScript = { targetFiles, img, out }: ''
      ln -s ${targetFiles} ${config.device}-target_files-${config.buildNumber}.zip || true
      ln -s ${img} ${config.device}-img-${config.buildNumber}.zip || true

      export DEVICE=${config.device};
      export PRODUCT=${config.device};
      export BUILD=${config.buildNumber};
      export VERSION=${toLower config.buildNumber};

      get_radio_image() {
        ${getBin pkgs.unzip}/bin/unzip -p ${targetFiles} OTA/android-info.txt  \
          |  grep -Po "require version-$1=\K.+" | tr '[:upper:]' '[:lower:]'
      }
      export BOOTLOADER=$(get_radio_image bootloader google_devices/$DEVICE)
      export RADIO=$(get_radio_image baseband google_devices/$DEVICE)

      export PATH=${getBin pkgs.zip}/bin:${getBin pkgs.unzip}/bin:$PATH
      ${pkgs.runtimeShell} ${config.source.dirs."device/common".src}/generate-factory-images-common.sh
      mv $PRODUCT-$VERSION-factory-*.zip ${out}
  '';

  otaMetadata = pkgs.runCommand "${config.device}-${config.channel}" {} ''
    ${pkgs.python3}/bin/python ${./generate_metadata.py} ${config.ota} > $out
  '';
in
{
  options = {
    channel = mkOption {
      default = "stable";
      type = types.strMatching "(stable|beta)";
      description = "Default channel to use for updates (can be modified in app)";
    };

    incremental = mkOption {
      default = false;
      type = types.bool;
      description = "Whether to include an incremental build in otaDir";
    };

    retrofit = mkOption {
      default = false;
      type = types.bool;
      description = "Generate a retrofit OTA for upgrading a device without dynamic partitions";
      # https://source.android.com/devices/tech/ota/dynamic_partitions/ab_legacy#generating-update-packages
    };

    # Build products. Put here for convenience--but it's not a great interface
    unsignedTargetFiles = mkOption { type = types.path; internal = true; };
    signedTargetFiles = mkOption { type = types.path; internal = true; };
    ota = mkOption { type = types.path; internal = true; };
    incrementalOta = mkOption { type = types.path; internal = true; };
    otaDir = mkOption { type = types.path; internal = true; };
    img = mkOption { type = types.path; internal = true; };
    factoryImg = mkOption { type = types.path; internal = true; };
    releaseScript = mkOption { type = types.path; internal = true;};

    prevBuildDir = mkOption { type = types.str; internal = true; };
    prevBuildNumber = mkOption { type = types.str; internal = true; };
    prevTargetFiles = mkOption { type = types.path; internal = true; };

    # Android 10 feature. This just disables the key generation/signing. TODO: Make it change the device configuration as well
    apex.enable = mkEnableOption "apex";

    apex.packageNames = mkOption {
      default = [];
      type = types.listOf types.str;
    };
  };

  config = with config; let # "with config" is ugly--but the scripts below get too verbose otherwise
    targetFiles = if signBuild then signedTargetFiles else unsignedTargetFiles;
  in {
    # These can be used to build these products inside nix. Requires putting the secret keys under /keys in the sandbox
    unsignedTargetFiles = mkDefault (build.android + "/${productName}-target_files-${buildNumber}.zip");
    signedTargetFiles = mkDefault (runWrappedCommand "signed_target_files" signedTargetFilesScript { targetFiles=unsignedTargetFiles;});
    ota = mkDefault (runWrappedCommand "ota_update" otaScript { inherit targetFiles; });
    incrementalOta = mkDefault (runWrappedCommand "incremental-${prevBuildNumber}" otaScript { inherit targetFiles prevTargetFiles; });
    img = mkDefault (runWrappedCommand "img" imgScript { inherit targetFiles; });
    factoryImg = mkDefault (runWrappedCommand "factory" factoryImgScript { inherit targetFiles img; });

    apex.packageNames = mkIf (apex.enable && (androidVersion >= 10))
      [ "com.android.conscrypt" "com.android.media"
        "com.android.media.swcodec" "com.android.resolv"
        "com.android.runtime.release" "com.android.tzdata"
      ];

    prevBuildNumber = let
        metadata = builtins.readFile (prevBuildDir + "/${device}-${channel}");
      in mkDefault (head (splitString " " metadata));
    prevTargetFiles = mkDefault (prevBuildDir + "/${device}-target_files-${prevBuildNumber}.zip");

    # TODO: target-files aren't necessary to publish--but are useful to include if prevBuildDir is set to otaDir output
    otaDir = pkgs.linkFarm "${device}-otaDir" (
      (map (p: {name=p.name; path=p;}) ([ ota otaMetadata ] ++ (optional incremental incrementalOta)))
      ++ [{ name="${device}-target_files-${buildNumber}.zip"; path=targetFiles; }]
    );

    # TODO: Do this in a temporary directory. It's ugly to make build dir and ./tmp/* dir gets cleared in these scripts too.
    # Maybe just remove this script? It's definitely complicated--and often untested
    releaseScript = mkDefault (pkgs.writeScript "release.sh" (''
      #!${pkgs.runtimeShell}
      export PREV_BUILDNUMBER=$2
      '' + (wrapScript { keysDir="$1"; commands=''
      if [[ "$KEYSDIR" ]]; then
        echo Signing target files
        ${signedTargetFilesScript { targetFiles=unsignedTargetFiles; out=signedTargetFiles.name; }} || exit 1
      fi
      echo Building OTA zip
      ${otaScript { targetFiles=signedTargetFiles.name; out=ota.name; }} || exit 1
      if [[ ! -z "$PREV_BUILDNUMBER" ]]; then
        echo Building incremental OTA zip
        ${otaScript {
          targetFiles=signedTargetFiles.name;
          prevTargetFiles="${device}-target_files-$PREV_BUILDNUMBER.zip";
          out="${device}-incremental-$PREV_BUILDNUMBER-${buildNumber}.zip";
        }} || exit 1
      fi
      echo Building .img file
      ${imgScript { targetFiles=signedTargetFiles.name; out=img.name; }} || exit 1
      echo Building factory image
      ${factoryImgScript { targetFiles=signedTargetFiles.name; img=img.name; out=factoryImg.name; }}
      ${pkgs.python3}/bin/python ${./generate_metadata.py} ${ota.name} > ${device}-${channel}
    ''; })));
  };
}
