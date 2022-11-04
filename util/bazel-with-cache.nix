{ stdenvNoCC
, writeScript
, writeText
}:

baseBazel: let
  diskCacheLocation = "/nix/var/cache/bazel";
  diskCacheBazelRc = writeText ".bazelrc.nix-disk-cache" ''
    build --disk_cache=${diskCacheLocation}
    build --incompatible_strict_action_env=true
    # build --action_env=PATH
    common --announce_rc=true
  '';

  bazelDiskCacheAdapterInner = base: let
    wrapped = writeScript "bazel-cached" ''
      #!/usr/bin/env bash
      BAZEL_DISK_CACHE_LOCATION="${diskCacheLocation}"
      extraStartupFlags=()

      if [ -d "$BAZEL_DISK_CACHE_LOCATION" ]; then
        echo "using bazel disk cache at $BAZEL_DISK_CACHE_LOCATION"
        extraStartupFlags+=(--bazelrc=${diskCacheBazelRc})
      fi

      exec ${base}/bin/bazel "''${extraStartupFlags[@]}" "''${@}"
    '';
  in
    stdenvNoCC.mkDerivation {
      inherit (base) pname version;
      unpackPhase = "true";
      installPhase = ''
        mkdir -p $out/bin
        cp ${wrapped} $out/bin/${base.pname}
      '';
    }
  ;
in let
  regular = bazelDiskCacheAdapterInner base;
  patch = x: x // {
    override = args: bazelDiskCacheAdapterInner (x.override args);
  };
in
  patch regular
