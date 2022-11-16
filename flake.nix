{
  description = "staging ground for IREE and friends packaged with nix";

  nixConfig = {
    extra-substituters = [
      "https://cache.garnix.io"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
    ];
  };

  inputs = {
    flu.url = github:numtide/flake-utils;
    nixpkgs.url = github:nixOS/nixpkgs/nixos-unstable;
  };

  outputs = { self, flu, nixpkgs }: let
    lib = nixpkgs.lib;
    versions = import ./versions.nix;

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

      versionOverrideGen = packageName: version: hashes: let
        inherit (pytorchWheelUrlGen { inherit packageName version; }) source;
      in {
        inherit version;
        sources =
          (source "x86_64" "linux" "310" hashes.linux-amd64) //
          # doesn't seem to be wheels for aarch64 linux...
          (source "x86_64" "darwin" "310" hashes.darwin-amd64) //
          (source "aarch64" "darwin" "310" hashes.darwin-aarch64);

          # omitting other python versions for now..
      };

      packageOverrides = py-final: py-prev: {
        inherit (let
          commonOverrides = old: {
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

            in old.postFixup + ''
              echo "cpp.cxx = (\"${cxxCompilerPath}\",) + cpp.cxx" \
                >> $out/${py-final.python.sitePackages}/torch/_inductor/config.py
            '';

            # Also test `functorch`, `dynamo`, and `inductor`:
            pythonImportsCheck = old.pythonImportsCheck ++ [
              "functorch" "torch._dynamo" "torch._inductor"
            ];
          };

          # Overrides for the binary (wheel) pytorch package:
          #
          # See: https://github.com/NixOS/nixpkgs/blob/9d556e2c7568cd2b84446618f635f8b3bcc19a2f/pkgs/development/python-modules/torch/bin.nix
          torch-bin = with versions; let
            # TODO(upstream): upstream the `versionOverride` changes
            versionOverride = versionOverrideGen "torch" torchVersion torchBinHashes;
          in lib.pipe ./pkgs/torch-bin.nix [
            (path: py-final.callPackage path { inherit versionOverride; })
            (pkg: pkg.overridePythonAttrs commonOverrides)
          ];

          # `torch-mlir` needs the pytorch library output so: we build pytorch
          # from source too:
          #
          # https://github.com/nixos/nixpkgs/blob/master/pkgs/development/python-modules/torch/default.nix
          torch = with versions; py-prev.torch.overridePythonAttrs (old: (commonOverrides old) // {
            version = torchVersion;

            src = final.fetchFromGitHub {
              owner = "pytorch";
              repo = "pytorch";
              fetchSubmodules = true;
              rev = torchSha;
              hash = torchSrcHash;
              preferLocalBuild = false;

              # Note: the `git_version` that pytorch picks up won't be set right
              # if `.git` isn't present so: we leave in `.git`.
              #
              # See: https://github.com/pytorch/pytorch/blob/093e22083613dd4b92c1ced20201edf713484a23/tools/generate_torch_version.py#L15
              leaveDotGit = true;

              # Note: with `leaveDotGit`, the hash is not stable: https://github.com/NixOS/nixpkgs/issues/8567
              #
              # So, we delete everything that isn't needed by
              # `git rev-parse HEAD` so eliminate sources of non-determinism:
              branchName = "main"; # don't want to rely on the default of `fetchgit` not changing..
              postFetch = ''
                # keep "HEAD" and "packed-refs", delete everything else:
                mkdir -p $out/.git2
                cp -R $out/.git/{HEAD,packed-refs} $out/.git2
                rm -rf $out/.git

                # delete all other git directories (submodules):
                find $out -iname .git | xargs rm -rf

                # move our git directory back into place
                mv $out/.git2 $out/.git
                mkdir -p $out/.git/{objects,refs} # stubs to make git happy
              '';
            };

            # In addition to leaving in `.git` we need to provide `git` so that
            # the pytorch build can pick up the git SHA.
            nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.git ];

            # TODO(upstream): we (nixpkgs) don't need to set this anymore; it's
            # no longer hardcoded in setup.py.
            #
            # This is set this here to _override_ this value from the torch
            # nixpkg.
            PYTORCH_BUILD_VERSION = torchVersion;
          });
        in {
          inherit torch torch-bin;
        }) torch torch-bin;

        # Same for `torchvision` and `torchvision-bin`:
        # https://github.com/NixOS/nixpkgs/blob/9d556e2c7568cd2b84446618f635f8b3bcc19a2f/pkgs/development/python-modules/torchvision/bin.nix
        torchvision-bin = with versions; let
          # TODO(upstream): upstream the `versionOverride` changes
          versionOverride = versionOverrideGen
            "torchvision" torchvisionVersion torchvisionBinHashes;
        in py-final.callPackage ./pkgs/torchvision-bin.nix {
          inherit versionOverride;
        };

        # https://github.com/NixOS/nixpkgs/blob/9d556e2c7568cd2b84446618f635f8b3bcc19a2f/pkgs/development/python-modules/torchvision/default.nix
        torchvision = with versions; py-prev.torchvision.overridePythonAttrs (old: {
          version = torchvisionVersion;
          src = final.fetchFromGitHub {
            owner = "pytorch";
            repo = "vision";
            rev = torchvisionSha;
            hash = torchvisionSrcHash;
            preferLocalBuild = false;
            leaveDotGit = true; # Same as `torch` -- we want `torchvision.version.git_version` to be correct
          };

          # See the `torch` derivation.
          nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.git ];

          # TODO(upstream): not sure why this is missing from the source package
          pythonImportsCheck = [ "torchvision" ];
        });
      };
    in {
      python37 = prev.python37.override { inherit packageOverrides; };
      python38 = prev.python38.override { inherit packageOverrides; };
      python39 = prev.python39.override { inherit packageOverrides; };
      python310 = prev.python310.override { inherit packageOverrides; };
    };

    llvmOverrides = final: prev: let
    in {
      clang_15 = final.llvmPackages_15.clang;
      clang-tools_15 = final.clang-tools_14.override {
        llvmPackages = final.llvmPackages_15;
      };
      lld_15 = final.llvmPackages_15.lld;
      lldb_15 = final.llvmPackages_15.lldb;
      llvm_15 = final.llvmPackages_15.llvm;
      llvmPackages_15 = lib.recurseIntoAttrs (final.callPackage ./pkgs/llvm/15 ({
        inherit (final.stdenvAdapters) overrideCC;
        buildLlvmTools = final.buildPackages.llvmPackages_15.tools;
        targetLlvmLibraries = final.targetPackages.llvmPackages_15.libraries
          or final.llvmPackages_15.libraries;
      } // lib.optionalAttrs
          (final.stdenv.hostPlatform.isi686 &&
            final.stdenv.hostPlatform == final.stdenv.buildPlatform &&
            final.buildPackages.stdenv.cc.isGNU)
        { stdenv = final.gcc7Stdenv; }
      ));

      python37 = prev.python37.override { inherit packageOverrides; };
      python38 = prev.python38.override { inherit packageOverrides; };
      python39 = prev.python39.override { inherit packageOverrides; };
      python310 = prev.python310.override { inherit packageOverrides; };
    };

    overlays = {
      inherit
        bazelUtilsOverlay ccachedStdenvOverlay pythonPackageOverrides
        llvmOverrides;
    };

    sysSpecific = with flu.lib; let
      systems = with flu.lib.system; [
        x86_64-linux
        aarch64-darwin
        # TODO: x86_64-darwin, aarch64-linux? etc.
      ];
    in eachSystem systems (system: let
      np = import nixpkgs {
        inherit system;

        overlays = builtins.attrValues overlays;

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
      packages = py: { bin ? false, src ? true }:
        (lib.optionalAttrs bin {
          inherit (py)
            torch-bin
            torchvision-bin
          ;
        }) // (lib.optionalAttrs src {
          inherit (py)
            torch
            torchvision
          ;
        });
      packagesSrc = packages py.pkgs { bin = false; };
      packagesBin = packages py.pkgs { bin = true; src = false; };
      packagesAll = packages py.pkgs { bin = true; src = true; };
      pyi = bin: extras: py.withPackages (p:
        (builtins.attrValues (packages p { bin = bin; src = !bin; }))
          ++ (extras p)
      );
      pyiSrc = pyi false (_: []);
      pyiBin = pyi true (_: []);
    in {
      # outputs keyed with `<system>`:
      devShells = {};
      apps = let
      in {
        python = { type = "app"; program = lib.getExe pyiSrc; };
        pythonWithBinPkgs = { type = "app"; program = lib.getExe pyiBin; };

        example = {
          type = "app";
          program = let
            useSourcePackages = true;
            interp = pyi (!useSourcePackages) (p: with p; [ requests ]);
          in lib.getExe (
            np.writeScriptBin "example" "${lib.getExe interp} ${./example.py}"
          );
        };
      };
      packages = (packagesAll) // {
        inherit (np) hello;

        inherit pyiSrc pyiBin;
        python = pyiSrc;

        inherit (np) llvm_15;
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

      inherit overlays;
    };
  in lib.recursiveUpdate sysSpecific sysIndep;
}
