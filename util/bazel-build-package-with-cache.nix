# Wrapper for `bazelBuildPackage` that removes some copts that are problematic
# for caching and makes a couple of other adjustments.

{ buildBazelPackage
, bazelWithCache
, lib
}:

{ buildAttrs ? { }
, bazel ? bazelWithCache # Defaults `bazel` to `bazelWithCache` if unspecified!
, bazelFlags ? []
, collectBuildExecutionTrace ? false
, ...
}@args:
let
  args' = (builtins.removeAttrs args ["collectBuildExecutionTrace"]) // {
    bazelFlags = bazelFlags ++ lib.optionals [
      "--execution_log_json_file=exec-log.json"
    ];

    buildAttrs = buildAttrs // {
      prebuild = ''
        # We don't want to have the package being built added to `NIX_LDFLAGS`
        # (with -rpath) because we usually don't need this and because this will
        # invalidate the cache everytime this package's derivation changes at
        # all.
        #
        # See:
        # https://github.com/nixos/nixpkgs/blob/master/pkgs/stdenv/generic/setup.sh#L625
        #
        # Note: we have to use a different variable name than `NIX_LDFLAGS` for
        # the array above; bash doesn't `export` variables that have array
        # types... (it just silently ignores `export`s on them and actually
        # _removes_ variables from the exports the moment they're `declare`'d
        # with array/etc types)
        declare -a NIX_LDFLAGS_ARR=(''${NIX_LDFLAGS[@]})
        for ((i = 0; i < ''${#NIX_LDFLAGS_ARR[@]}; i++)); do
            if [[ "''${NIX_LDFLAGS_ARR[$i]}" == "-rpath" ]] &&
              [[ "''${NIX_LDFLAGS_ARR[$((i + 1))]}" =~ "$out"/* ]]; then
                unset "NIX_LDFLAGS_ARR[i]"
                unset "NIX_LDFLAGS_ARR[i + 1]"
            fi
        done
        export NIX_LDFLAGS="''${NIX_LDFLAGS_ARR[*]}"

        # As with `ccached-stdenv-wrapper`, we want to drop the `-frandom-seed`
        # flag that the nix stdenv injects.
        #
        # See: https://github.com/NixOS/nixpkgs/issues/109033
        #
        # Bazel has it's own handling for `-frandom-seed` and reproducibility
        # anyways: https://github.com/bazelbuild/bazel/commit/2a6a629b25358eb3320893fc8adba0aace0d173e#diff-f501d00fb1a93685f76a71cb4c8eb5a9b01629cafefe1c4009ae3a3ae3d89195R741-R753
        declare -a NIX_CFLAGS_COMPILE_ARR=(''${NIX_CFLAGS_COMPILE[@]})
        for ((i = 0; i < ''${#NIX_CFLAGS_COMPILE_ARR[@]}; i++)); do
            case ''${NIX_CFLAGS_COMPILE_ARR[$i]} in
                -frandom-seed=*) unset "NIX_CFLAGS_COMPILE_ARR[i]"; break;;
            esac
        done
        export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE_ARR[*]}"

        # We want to use the absolute path of our compilers in the env vars
        # Bazel's `local_cc_toolchain` will be configured with so that Bazel
        # knows to invalidate the cache when our compiler changes:
        r() { export $1=$(realpath $(which ''${!1})); }
        r CC; r CXX; r AS; r LD
        r AR; r RANLIB
        r NM; r READELF; r SIZE; r OBJCOPY; r OBJDUMP
      '' ++ buildAttrs.prebuild or "";

      installPhase = buildAttrs.installPhase or "" + (
        lib.string.optionalString collectBuildExecutionTrace ''
          mkdir -p $out
          cp exec-log.json $out/
        ''
      );
    };
  };
in buildBazelPackage args'
