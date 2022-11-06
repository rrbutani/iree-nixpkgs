# `iree-nixpkgs`

Staging ground for IREE and friends packaged with `nix`.

---

### Setup

  0) [Install `nix`](https://nixos.org/download.html#download-nix)
      + Prefer the multi-user installation
      + If you don't have root access see: TODO
  1) [Enable flakes](https://nixos.wiki/wiki/Flakes#Permanent)
  2) (Optional) Make a compile cache dir and add it to your sandbox's exemptions
      1) Make `/nix/var/cache/bazel` and `/nix/var/cache/ccache`, set permissions so nix can modify this directory while building:
          + multi-user installation:
            ```bash
            sudo mkdir -p /nix/var/cache/ccache /nix/var/cache/bazel
            sudo chgrp nixbld -R /nix/var/cache
            sudo chmod 775 -R /nix/var/cache
            ```
          + single-user installation:
            ```bash
            # Can omit `sudo` if using a rootless chroot based installation.
            sudo mkdir -p /nix/var/cache/ccache /nix/var/cache/bazel
            sudo chgrp $USER /nix/var/cache
            sudo chmod 755 -R /nix/var/cache
            ```
      2) Add `/nix/var/cache` to the extra sandbox paths:
          + if using NixOS/home-manager:
            ```nix
            nix.settings.extra-sandbox-paths = [
              "/nix/var/cache"
            ];
            ```
          + otherwise add this to `/etc/nix/nix.conf` (or `~/.config/nix/nix.conf` for single-user installations):
            ```ini
            extra-sandbox-paths = /nix/var/cache
            ```
  3) ???


### TODO

  - [x] add an option for using custom wheels to `torch-bin`
    + [x] test `_dyanmo`, `functorch`, `_inductor`
  - [x] update `torch` (source package) to build the nightly version
    + needed for `torch-mlir` (torchlib)
  - [x] add an option for using custom wheels to `torchvision-bin`
  - [x] update `torchvision` (source package) to build the nightly version
    + might as well
  - [ ] `torchtext`
    * See: https://github.com/NixOS/nixpkgs/pull/160207/files
  - [ ] `torchtext-bin` with an option for using custom wheels
  - [ ] `accelerate`
  - [ ] `iopath`
  - [ ] `pytorch-image-models`
  - [ ] `huggingface_hub`
  - [ ] `MonkeyType`
  - [ ] ? `submitit`
  - [ ] `torchbench`
  - [ ] `torchbench-bin`

  - [ ] llvm 15
  - [ ] add mlir
  - [ ] update LLVM git, add options to specify url, source, etc.
  - [ ] `torch-mlir`
    + requires MLIR/LLVM for source build; we should do an out-of-tree build and use `llvmPackages`
    + should default to having the version be that corresponding to LLVM 15
    + override the pytorchbin version to something that's compatible...
      * make this overidable (specify the pytorch package to use)
  - [ ] `torch-mlir-bin`

  - [ ] `iree` (C++)
    + no sense in having this use the MLIR/LLVM in nixpkgs; build isn't set up for it + `iree` uses it's own LLVM fork
  - [ ] `iree-bin` (C++)
    + [ ] `iree-dist`; point is to save yourself the build cost + easy override (specify version or URL outright)

  - [ ] IREE python packages:
    + [ ] `iree-compiler`
    + [ ] `iree-runtime` / `iree-runtime-instrumented`
      * these _can_ use `iree-run-module`/`iree-benchmark-module` from the iree package but... maybe don't bother? these aren't big binaries and not sure we can get the build sys to back off on building these anyways
    + [ ] `iree-tools-xla`
    + [ ] `iree-tools-tflite`
    + [ ] `iree-tools-tf`
    + unclear how these should interact with the C++ package, if at all..
      * perhaps version/source should come from the `iree` package?
  - [ ] IREE python bin packages
    + (with version override..)

  - [ ] `iree-torch` (don't bother with bin, no binary components)

  - [ ] `shark`
  - [ ] `shark-bin`
