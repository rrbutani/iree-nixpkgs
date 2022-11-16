{ lowPrio, newScope, pkgs, lib, stdenv, cmake, ninja
, gccForLibs, preLibcCrossHeaders
, libxml2, python3, isl, fetchFromGitHub, overrideCC, wrapCCWith, wrapBintoolsWith
, buildLlvmTools # tools, but from the previous stage, for cross
, targetLlvmLibraries # libraries, but from the next stage, for cross
# This is the default binutils, but with *this* version of LLD rather
# than the default LLVM verion's, if LLD is the choice. We use these for
# the `useLLVM` bootstrapping below.
, bootBintoolsNoLibc ?
    if stdenv.targetPlatform.linker == "lld"
    then null
    else pkgs.bintoolsNoLibc
, bootBintools ?
    if stdenv.targetPlatform.linker == "lld"
    then null
    else pkgs.bintools
, darwin
# LLVM release information; specify one of these but not both:
, gitRelease ? null
  # i.e.:
  # {
  #   version = /* i.e. "15.0.0" */;
  #   rev = /* commit SHA */;
  #   rev-version = /* human readable version; i.e. "unstable-2022-26-07" */;
  #   sha256 = /* checksum for this release, can omit if specifying your own `monorepoSrc` */;
  # }
, officialRelease ? { version = "15.0.4"; sha256 = "sha256-kqF3l2RdTvTxUy71YCjUDsv/zTlmzoGyZB+DkzTps0g="; }
  # i.e.:
  # {
  #   version = /* i.e. "15.0.0" */;
  #   candidate = /* optional; if specified, should be: "rcN" */
  #   sha256 = /* checksum for this release, can omit if specifying your own `monorepoSrc` */;
  # }
# By default, we'll try to fetch a release from `github:llvm/llvm-project`
# corresponding to the `gitRelease` or `officialRelease` specified.
#
# You can provide your own LLVM source by specifying this arg but then it's up
# to you to make sure that the LLVM repo given matches the release configuration
# specified.
, monorepoSrc ? null
}:

assert let
  int = a: if a then 1 else 0;
  xor = a: b: ((builtins.bitXor (int a) (int b)) == 1);
in
  lib.assertMsg
    (xor
      (gitRelease != null)
      (officialRelease != null))
    ("must specify `gitRelease` or `officialRelease`" +
      (lib.optionalString (gitRelease != null) " — not both"));
let
  monorepoSrc' = monorepoSrc;
in let
  releaseInfo = if gitRelease != null then rec {
    original = gitRelease;
    release_version = original.version;
    version = gitRelease.rev-version;
  } else rec {
    original = officialRelease;
    release_version = original.version;
    version = if original ? candidate then
      "${release_version}-${original.candidate}"
    else
      release_version;
  };

  monorepoSrc = if monorepoSrc' != null then
    monorepoSrc'
  else let
    sha256 = releaseInfo.original.sha256;
    rev = if gitRelease != null then
      gitRelease.rev
    else
      "llvmorg-${releaseInfo.version}";
  in fetchFromGitHub {
    owner = "llvm";
    repo = "llvm-project";
    inherit rev sha256;
  };

  inherit (releaseInfo) release_version version;

  llvm_meta = {
    license     = lib.licenses.ncsa;
    maintainers = with lib.maintainers; [ lovek323 raskin dtzWill primeos ];
    platforms   = lib.platforms.all;
  };

  tools = lib.makeExtensible (tools: let
    callPackage = newScope (tools // { inherit stdenv cmake ninja libxml2 python3 isl release_version version monorepoSrc buildLlvmTools; });
    mkExtraBuildCommands0 = cc: ''
      rsrc="$out/resource-root"
      mkdir "$rsrc"
      ln -s "${cc.lib}/lib/clang/${release_version}/include" "$rsrc"
      echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
    '';
    mkExtraBuildCommands = cc: mkExtraBuildCommands0 cc + ''
      ln -s "${targetLlvmLibraries.compiler-rt.out}/lib" "$rsrc/lib"
      ln -s "${targetLlvmLibraries.compiler-rt.out}/share" "$rsrc/share"
    '';

  bintoolsNoLibc' =
    if bootBintoolsNoLibc == null
    then tools.bintoolsNoLibc
    else bootBintoolsNoLibc;
  bintools' =
    if bootBintools == null
    then tools.bintools
    else bootBintools;

  in {

    libllvm = callPackage ./llvm {
      inherit llvm_meta;
    };

    # `llvm` historically had the binaries.  When choosing an output explicitly,
    # we need to reintroduce `outputSpecified` to get the expected behavior e.g. of lib.get*
    llvm = tools.libllvm.out // { outputSpecified = false; };

    libclang = callPackage ./clang {
      inherit llvm_meta;
    };

    clang-unwrapped = tools.libclang.out // { outputSpecified = false; };

    llvm-manpages = lowPrio (tools.libllvm.override {
      enableManpages = true;
      python3 = pkgs.python3;  # don't use python-boot
    });

    clang-manpages = lowPrio (tools.libclang.override {
      enableManpages = true;
      python3 = pkgs.python3;  # don't use python-boot
    });

    lldb-manpages = lowPrio (tools.lldb.override {
      enableManpages = true;
      python3 = pkgs.python3;  # don't use python-boot
    });

    # pick clang appropriate for package set we are targeting
    clang =
      /**/ if stdenv.targetPlatform.useLLVM or false then tools.clangUseLLVM
      else if (pkgs.targetPackages.stdenv or stdenv).cc.isGNU then tools.libstdcxxClang
      else tools.libcxxClang;

    libstdcxxClang = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      # libstdcxx is taken from gcc in an ad-hoc way in cc-wrapper.
      libcxx = null;
      extraPackages = [
        targetLlvmLibraries.compiler-rt
      ];
      extraBuildCommands = mkExtraBuildCommands cc;
    };

    libcxxClang = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = targetLlvmLibraries.libcxx;
      extraPackages = [
        targetLlvmLibraries.libcxxabi
        targetLlvmLibraries.compiler-rt
      ];
      extraBuildCommands = mkExtraBuildCommands cc;
    };

    lld = callPackage ./lld {
      inherit llvm_meta;
    };

    lldb = callPackage ./lldb {
      inherit llvm_meta;
      inherit (darwin) libobjc bootstrap_cmds;
      inherit (darwin.apple_sdk.libs) xpc;
      inherit (darwin.apple_sdk.frameworks) Foundation Carbon Cocoa;
    };

    mlir = callPackage ./mlir {
      inherit llvm_meta;
    };

    # mlir-python = mlir.python-bindings;
    # mlir-vscode = mlir.vscode-extension;

    # Below, is the LLVM bootstrapping logic. It handles building a
    # fully LLVM toolchain from scratch. No GCC toolchain should be
    # pulled in. As a consequence, it is very quick to build different
    # targets provided by LLVM and we can also build for what GCC
    # doesn’t support like LLVM. Probably we should move to some other
    # file.

    bintools-unwrapped = callPackage ./bintools {};

    bintoolsNoLibc = wrapBintoolsWith {
      bintools = tools.bintools-unwrapped;
      libc = preLibcCrossHeaders;
    };

    bintools = wrapBintoolsWith {
      bintools = tools.bintools-unwrapped;
    };

    clangUseLLVM = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = targetLlvmLibraries.libcxx;
      bintools = bintools';
      extraPackages = [
        targetLlvmLibraries.libcxxabi
        targetLlvmLibraries.compiler-rt
      ] ++ lib.optionals (!stdenv.targetPlatform.isWasm) [
        targetLlvmLibraries.libunwind
      ];
      extraBuildCommands = mkExtraBuildCommands cc;
      nixSupport.cc-cflags =
        [ "-rtlib=compiler-rt"
          "-Wno-unused-command-line-argument"
          "-B${targetLlvmLibraries.compiler-rt}/lib"
        ]
        ++ lib.optional (!stdenv.targetPlatform.isWasm) "--unwindlib=libunwind"
        ++ lib.optional
          (!stdenv.targetPlatform.isWasm && stdenv.targetPlatform.useLLVM or false)
          "-lunwind"
        ++ lib.optional stdenv.targetPlatform.isWasm "-fno-exceptions";
    };

    clangNoLibcxx = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = null;
      bintools = bintools';
      extraPackages = [
        targetLlvmLibraries.compiler-rt
      ];
      extraBuildCommands = mkExtraBuildCommands cc;
      nixSupport.cc-cflags = [
        "-rtlib=compiler-rt"
        "-B${targetLlvmLibraries.compiler-rt}/lib"
        "-nostdlib++"
      ];
    };

    clangNoLibc = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = null;
      bintools = bintoolsNoLibc';
      extraPackages = [
        targetLlvmLibraries.compiler-rt
      ];
      extraBuildCommands = mkExtraBuildCommands cc;
      nixSupport.cc-cflags = [
        "-rtlib=compiler-rt"
        "-B${targetLlvmLibraries.compiler-rt}/lib"
      ];
    };

    clangNoCompilerRt = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = null;
      bintools = bintoolsNoLibc';
      extraPackages = [ ];
      extraBuildCommands = mkExtraBuildCommands0 cc;
      nixSupport.cc-cflags = [ "-nostartfiles" ];
    };

    clangNoCompilerRtWithLibc = wrapCCWith rec {
      cc = tools.clang-unwrapped;
      libcxx = null;
      bintools = bintools';
      extraPackages = [ ];
      extraBuildCommands = mkExtraBuildCommands0 cc;
    };

  });

  libraries = lib.makeExtensible (libraries: let
    callPackage = newScope (libraries // buildLlvmTools // { inherit stdenv cmake ninja libxml2 python3 isl release_version version monorepoSrc; });
  in {

    compiler-rt-libc = callPackage ./compiler-rt {
      inherit llvm_meta;
      stdenv = if stdenv.hostPlatform.useLLVM or false
               then overrideCC stdenv buildLlvmTools.clangNoCompilerRtWithLibc
               else stdenv;
    };

    compiler-rt-no-libc = callPackage ./compiler-rt {
      inherit llvm_meta;
      stdenv = if stdenv.hostPlatform.useLLVM or false
               then overrideCC stdenv buildLlvmTools.clangNoCompilerRt
               else stdenv;
    };

    # N.B. condition is safe because without useLLVM both are the same.
    compiler-rt = if stdenv.hostPlatform.isAndroid
      then libraries.compiler-rt-libc
      else libraries.compiler-rt-no-libc;

    stdenv = overrideCC stdenv buildLlvmTools.clang;

    libcxxStdenv = overrideCC stdenv buildLlvmTools.libcxxClang;

    libcxxabi = let
      # CMake will "require" a compiler capable of compiling C++ programs
      # cxx-header's build does not actually use one so it doesn't really matter
      # what stdenv we use here, as long as CMake is happy.
      cxx-headers = callPackage ./libcxx {
        inherit llvm_meta;
        headersOnly = true;
      };

      # `libcxxabi` *doesn't* need a compiler with a working C++ stdlib but it
      # *does* need a relatively modern C++ compiler (see:
      # https://releases.llvm.org/15.0.0/projects/libcxx/docs/index.html#platform-and-compiler-support).
      #
      # So, we use the clang from this LLVM package set, like libc++
      # "boostrapping builds" do:
      # https://releases.llvm.org/15.0.0/projects/libcxx/docs/BuildingLibcxx.html#bootstrapping-build
      #
      # We cannot use `clangNoLibcxx` because that contains `compiler-rt` which,
      # on macOS, depends on `libcxxabi`, thus forming a cycle.
      stdenv_ = overrideCC stdenv buildLlvmTools.clangNoCompilerRtWithLibc;
    in callPackage ./libcxxabi {
      stdenv = stdenv_;
      inherit llvm_meta cxx-headers;
    };

    # Like `libcxxabi` above, `libcxx` requires a fairly modern C++ compiler,
    # so: we use the clang from this LLVM package set instead of the regular
    # stdenv's compiler.
    libcxx = callPackage ./libcxx {
      inherit llvm_meta;
      stdenv = overrideCC stdenv buildLlvmTools.clangNoLibcxx;
    };

    libunwind = callPackage ./libunwind {
      inherit llvm_meta;
      stdenv = overrideCC stdenv buildLlvmTools.clangNoLibcxx;
    };

    openmp = callPackage ./openmp {
      inherit llvm_meta;
    };
  });

in { inherit tools libraries release_version; } // libraries // tools
