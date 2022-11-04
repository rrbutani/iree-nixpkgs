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
      packageOverrides = py-final: py-prev: {
        # We want a specific pytorch version but don't need to add in our own
        # patches or modifications so we just override the source of the (very
        # convenient) bin variant of the pytorch package:
        #
        # See: https://github.com/NixOS/nixpkgs/blob/9d556e2c7568cd2b84446618f635f8b3bcc19a2f/pkgs/development/python-modules/torch/bin.nix
        pytorch-bin = let
          # TODO(upstream): upstream the `versionOverride` changes
          versionOverride = let
            version = "1.14.0.dev20221104"; # remember to update the hashes!

            # Note: we're *not* using the CUDA versions.
            baseUrl = "https://download.pytorch.org/whl/nightly/cpu";

            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev20221104-cp39-none-macosx_11_0_arm64.whl
            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev20221104-cp37-none-macosx_10_9_x86_64.whl
            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev20221101%2Bcpu-cp37-cp37m-linux_x86_64.whl
            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev20221101%2Bcpu-cp38-cp38-linux_x86_64.whl
            #
            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev2022104-cp310-cp310-linux_x86_64.whl
            # https://download.pytorch.org/whl/nightly/cpu/torch-1.14.0.dev2022104%2Bcpu-cp310-cp310-linux_x86_64.whl

            name = { pyi, os, arch }: "torch-${version}${pyi}-${os}_${arch}.whl";
            url = args: baseUrl + "/" + (name args);

            source = arch: os: py: hash: let
              pyi = if os == "darwin" then
                  "-cp${py}-none"
                else
                  if py == "37" then "%2Bcpu-cp37-cp37m" else "%2Bcpu-cp${py}-cp${py}";
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
          in {
            inherit version;
            sources =
              (source "x86_64" "linux" "37" "") //
              (source "x86_64" "linux" "38" "") //
              (source "x86_64" "linux" "39" "") //
              (source "x86_64" "linux" "310" "sha256-t8b/e4QNUF1yjQCr2c6DRZYkgVI8tNNai8uIULXr9Uc=") //

              (source "x86_64" "darwin" "37" "") //
              (source "x86_64" "darwin" "38" "") //
              (source "x86_64" "darwin" "39" "") //
              (source "x86_64" "darwin" "310" "") //

              (source "aarch64" "darwin" "37" "") //
              (source "aarch64" "darwin" "38" "") //
              (source "aarch64" "darwin" "39" "") //
              (source "aarch64" "darwin" "310" "") //
              {};
          };
        in lib.pipe ./pkgs/pytorch-bin.nix [
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
      apps = {
        python = let
          pyi = py.withPackages (p: with p; [ pytorch-bin ]);
        in { type = "app"; program = lib.getExe pyi; };
      };
      packages = {
        inherit (np) hello;
        /*
        hello = np.hello.overrideDerivation (_: {
          huh = " ";
          NIX_DEBUG = 4;
        });
        */

        inherit (py.pkgs) pytorch-bin;
        python = py.withPackages (p: with p; [ pytorch-bin ]);
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
