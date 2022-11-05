{
  description = "staging ground for IREE and friends packaged with nix";

  # TODO: cachix

  inputs = {
    flu.url = github:numtide/flake-utils;
    nixpkgs.url = github:nixOS/nixpkgs/nixos-unstable;
  };

  outputs = { self, flu, nixpkgs }: let
    lib = nixpkgs.lib;

    bazelUtilsOverlay = final: prev: rec {
      bazelDiskCacheAdapter = final.callPackage ./util/bazel-with-cache.nix {};

      bazelWithCache = bazelDiskCacheAdapter final.bazel;
      bazel_4_WithCache = bazelDiskCacheAdapter final.bazel_4;
      bazel_5_WithCache = bazelDiskCacheAdapter final.bazel_5;
      bazel_6_WithCache = bazelDiskCacheAdapter final.bazel_6;

      buildBazelPackageWithCache = final.callPackage ./util/bazel-build-package-with-cache.nix {
        bazelWithCache = final.bazel_5_WithCache;
      };
    };

    ccachedStdenvAdapter = import ./util/ccached-stdenv-wrapper.nix;
    ccachedStdenvOverlay = final: prev: {
      stdenvCcache = ccachedStdenvAdapter {
        nixpkgs = prev;
        ccache = final.buildPackages.ccache;
      };
    };

    pythonPackageOverrides = final: prev: let
      pytorchWheelUrlGen = {
        packageName ? "torch",
        version,
        # Note: we're *not* using the CUDA versions.
        baseUrl ? "https://download.pytorch.org/whl/nightly/cpu"
      }: rec {
        name = { pyi, os, arch }: "${packageName}-${version}${pyi}-${os}_${arch}.whl";
        url = args: baseUrl + "/" + (name args);
        source = arch: os: py: hash: let
          pyi = if os == "darwin" && packageName == "torch" then
              "-cp${py}-none"
            else let
              ext = if py == "37" then "m" else "";
              pre = if os == "linux" then "%2Bcpu" else "";
            in pre + "-cp${py}-cp${py}" + ext;
          arch' = if arch == "aarch64" then "arm64" else arch;
          os' = if os == "darwin" then
              if arch == "aarch64" then "macosx_11_0" else "macosx_10_9"
            else os;
          args = { inherit pyi; os = os'; arch = arch'; };
        in {
          "${arch}-${os}-${py}" = {
            name = name args;
            url = url args;
            inherit hash;
          };
        };
      };

      torchVersion = "1.14.0.dev20221104"; # remember to update the hashes!
      torchvisionVersion = "0.15.0.dev20221104"; # remember to update the hashes!

      packageOverrides = py-final: py-prev: {
        # We want a specific pytorch version but don't need to add in our own
        # patches or modifications so we just override the source of the (very
        # convenient) bin variant of the pytorch package:
        #
        # See: https://github.com/NixOS/nixpkgs/blob/9d556e2c7568cd2b84446618f635f8b3bcc19a2f/pkgs/development/python-modules/torch/bin.nix
        torch-bin = let
          # TODO(upstream): upstream the `versionOverride` changes
          versionOverride = let
            version = torchVersion;
            inherit (pytorchWheelUrlGen {
              packageName = "torch"; inherit version;
            }) source;
          in {
            inherit version;
            sources =
              (source "x86_64" "linux" "310" "sha256-t8b/e4QNUF1yjQCr2c6DRZYkgVI8tNNai8uIULXr9Uc=") //
              (source "x86_64" "darwin" "310" "") //
              (source "aarch64" "darwin" "310" "");
          };
        in lib.pipe ./pkgs/torch-bin.nix [
          (path: py-final.callPackage path {
            inherit versionOverride;
          })

          (pkg: pkg.overridePythonAttrs (old: {
            propagatedBuildInputs = with py-final; old.propagatedBuildInputs ++ [
              networkx # new dep
              sympy # new dep

              # torch inductor depends on this but this isn't in setup.py...
              filelock
            ];

            # inductor uses a C++ compiler at runtime; we want it to default
            # to using the C++ compiler in our target's stdenv
            postFixup = let
              # TODO: is this right for cross compilation? needs testing
              #
              # I _think_, since the target platform compiler (i.e. the compiler
              # that runs on the target platform and produces binaries for the
              # target platform) is never a cross compiler, it does not have a
              # prefix.
              cxxCompilerPath = "${final.targetPackages.stdenv.cc}/bin/c++";

              # echo "cpp.cxx = (\"$(realpath "$(which $CC)")\",) + cpp.cxx" \
            in old.postFixup + ''
              echo "cpp.cxx = (\"${cxxCompilerPath}\",) + cpp.cxx" \
                >> $out/${py-final.python.sitePackages}/torch/_inductor/config.py
            '';
          }))
        ];
      };
    in {
      python37 = prev.python37.override { inherit packageOverrides; };
      python38 = prev.python38.override { inherit packageOverrides; };
      python39 = prev.python39.override { inherit packageOverrides; };
      python310 = prev.python310.override { inherit packageOverrides; };
    };

    sysSpecific = flu.lib.eachDefaultSystem (system: let
      np = import nixpkgs {
        inherit system;

        overlays = [
          bazelUtilsOverlay
          ccachedStdenvOverlay
          pythonPackageOverrides
        ];

        # broken:
        #  - some autoconf tests don't work (c-ares)
        #  - inclusion of outputs paths in the command line make this not useful
        #    at all
        #    + need to either: use ca-derivations (other issues...)
        #    + rewrite these paths before the cmake hasher runs
        /*
        config.replaceStdenv = { pkgs }: ccachedStdenvAdapter {
          nixpkgs = pkgs;
        };
        */
      };

      py = np.python310;
    in {
      # outputs keyed with `<system>`:

      devShells = {};
      apps = let
        pyi = py.withPackages (p: with p; [
          torch-bin
        ]);
      in {
        python = { type = "app"; program = lib.getExe pyi; };

        example = {
          type = "app";
          program = lib.getExe (
            np.writeScriptBin "example" "${lib.getExe pyi} ${./example.py}"
          );
        };
      };
      packages = {
        inherit (np) hello;

        inherit (py.pkgs) torch-bin;
      };
      checks = {};

      nixpkgs = np;
    });

    sysIndep = {
      # system independent outputs:
      lib = {
        inherit ccachedStdenvAdapter;
        bazelDiskCacheAdapter = import ./util/bazel-with-cache.nix;
      };

      overlays = {
        inherit bazelUtilsOverlay ccachedStdenvOverlay pythonPackageOverrides;
      };
    };
  in lib.recursiveUpdate sysSpecific sysIndep;
}
