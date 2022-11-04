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

