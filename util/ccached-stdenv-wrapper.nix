let
  # See: https://github.com/leanprover/lean4/blob/b40cf1d1712ae7b1585ecd75a533a5fb3030bded/nix/packages.nix#L18-L31
  # (!!!: if you change this you invalidate ccache's cache!)
  ccacheExtraConfig = cc: ''
    export CCACHE_DIR=/nix/var/cache/ccache
    [ -d $CCACHE_DIR ] || {
      if [[ $NIX_DEBUG -ge 4 ]]; then
        echo "warning: cache dir '$CCACHE_DIR' not present; not using ccache" >&2
      fi
      exec ${cc}/bin/$(basename "$0") "$@";
    }

    # export CCACHE_UMASK=007
    export CCACHE_COMPRESS=true
    export CCACHE_BASEDIR=$NIX_BUILD_TOP
    # See: https://github.com/NixOS/nixpkgs/issues/109033
    args=("$@")
    for ((i=0; i<"''${#args[@]}"; i++)); do
      case ''${args[i]} in
        -frandom-seed=*) unset args[i]; break;;
      esac
    done
    set -- "''${args[@]}"
    if [[ $NIX_DEBUG -ge 4 ]]; then
      echo "CCACHE debug mode enabled" >&2
      export CCACHE_DEBUG=true
      export CCACHE_LOGFILE="$CCACHE_DIR/log"
      export CCACHE_DEBUGDIR="$CCACHE_DEBUG/debug"
      echo "''${args[@]}" >> "$CCACHE_DIR/stdenv-cmd-log"
    fi
  '';
  cachedStdenv = { nixpkgs, stdenv ? nixpkgs.stdenv, ccache ? nixpkgs.buildPackages.ccache }:
    let
      ccacheWrapper' = { extraConfig, cc }: let
        # Some packages (conditionally) expect these attributes to be on
        # `stdenv.cc.cc`.
        attrsToForward = [
          "libllvm"
          # "python"
          # "metadata"
          "version"
        ];
        innerCcAttrs = let
          attrsToForwardMap = builtins.listToAttrs (builtins.map (n: {
            name = n; value = true;
          }) attrsToForward);
        in
          nixpkgs.lib.attrsets.filterAttrs
            (n: _: attrsToForwardMap.${n} or false)
            cc.cc;
        # ccache = nixpkgs.buildPackages.ccache.overrideAttrs (o: {
        #   doCheck = false;
        # });
        wrapped = cc.override {
          cc = innerCcAttrs // (ccache.links {
            inherit extraConfig;
            unwrappedCC = cc.cc;
          });
        };
      in
        wrapped;

      ccacheWrapper = nixpkgs.makeOverridable ccacheWrapper' {
        extraConfig = ccacheExtraConfig stdenv.cc.cc;
        inherit (stdenv) cc;
      };

      ccacheWrapperNoResponseFiles = ccacheWrapper.overrideAttrs (old: {
        # https://github.com/NixOS/nixpkgs/issues/119779
        installPhase = builtins.replaceStrings ["use_response_file_by_default=1"] ["use_response_file_by_default=0"] old.installPhase;
      });

      ccacheStdenv' = { stdenv, ... } @ extraArgs:
        nixpkgs.overrideCC stdenv (ccacheWrapperNoResponseFiles.override ({
          cc = stdenv.cc;
        } // nixpkgs.lib.optionalAttrs (builtins.hasAttr "extraConfig" extraArgs) {
          extraConfig = extraArgs.extraConfig;
        }));

      cachedStdenv = nixpkgs.lowPrio (ccacheStdenv' { inherit stdenv; });
      # cachedStdenv = nixpkgs.lowPrio (nixpkgs.lib.makeOverridable ccacheStdenv' { inherit stdenv; }); # TODO: not sure why this breaks everything...
    in
      cachedStdenv;
in
  cachedStdenv

