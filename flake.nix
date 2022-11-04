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
