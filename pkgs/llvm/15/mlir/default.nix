{ lib, stdenv, llvm_meta
, monorepoSrc, runCommand
, cmake, ninja
, python3
, libllvm
, version

# TODO: python bindings
, enablePython ? true

, enableDocs ? true # TODO: share/doc
, doxygen
, graphviz

# TODO: vscode extension as a pass-through

# TODO: ROCm, CUDA ?
# TODO: Tests (unit+lit), not integration `INCLUDE_TESTS`
, enableRunners ? stdenv.hostPlatform == stdenv.buildPlatform
, enableVulkan ? enableRunners
, vulkan-headers
, vulkan-loader

# For tests:
, fetchurl
}:

# TODO:
#  - [ ] python
#  - [ ] docs
#  - [ ] tests
#  - [ ] vscode-extension

let
  # # List of runners to build, native-only
  # runners = lib.optionals enableRunners ([
  #   "cpu-runner" "spirv-cpu-runner"
  # ] ++ lib.optional enableVulkan "vulkan-runner");
  # # List of binaries to build + install
  # # LLVM_{BUILD,INSTALL}_UTILS=ON doesn't seem to work
  # bins = map (n: "mlir-" + n) (runners ++ [
  #   "linalg-ods-yaml-gen" "tblgen" # needed for cross
  #   "lsp-server" "opt" "pdll" "reduce" "translate" # misc utilities
  # ]);

  # TODO: is ^ required?

  pyPkgs = python3.pkgs;
  pythonRuntimeDeps = with pyPkgs; [
    numpy
    pyyaml
  ];
in let mlir = stdenv.mkDerivation rec {
  pname = "mlir";
  inherit version;

  src = runCommand "${pname}-src-${version}" {} ''
    mkdir -p "$out"
    cp -r ${monorepoSrc}/cmake "$out"
    cp -r ${monorepoSrc}/${pname} "$out"
  '';

  sourceRoot = "${src.name}/${pname}";

  patches = [
    ./gnu-install-dirs.patch

    # Follows the conventions `flang` and other LLVM sub-projects use for
    # enabling doxygen doc builds when the sub-project is built standalone (not
    # as part of an LLVM build).
    ./standalone-docs-build-support.patch

    # We can't just move the `python_packages` directory after the fact because
    # the package embeds some absolute paths (i.e. the path to the C API's
    # include directory).
    ./patch-python-install-location.patch
  ];

  outputs = [ "out" "lib" "dev" ]
    ++ (lib.optional enablePython "python") # TODO
    ++ (lib.optional enableDocs "doc"); # TODO

  nativeBuildInputs = [
    cmake ninja python3
  ] ++ lib.optionals enablePython ([ pyPkgs.pybind11 ]
    # Note: we're putting these "runtime" deps here instead of in
    # `propagatedBuildInputs` because we do not actually want these to be
    # propagated on this derivation (see `passthru.python-bindings` below).
    ++ pythonRuntimeDeps
  ) ++ lib.optionals enableDocs [
    doxygen graphviz
  ];
  buildInputs = [ libllvm ]
    ++ lib.optionals enableVulkan [ vulkan-headers vulkan-loader ];

  cmakeFlags = [
    # Documentation suggests packagers may wish to disable, do so until needed
    "-DMLIR_INSTALL_AGGREGATE_OBJECTS=OFF"

    "-DMLIR_INSTALL_PACKAGE_DIR=${placeholder "dev"}/lib/cmake/mlir"

    # So that the binaries are added to the install target:
    "-DLLVM_BUILD_TOOLS=ON"

    "-DMLIR_INCLUDE_TESTS=${if doCheck then "ON" else "OFF"}"
    "-DMLIR_ENABLE_BINDINGS_PYTHON=${if enablePython then "ON" else "OFF"}"
    "-DMLIR_INCLUDE_DOCS=${if enableDocs then "ON" else "OFF"}"
  ] ++ lib.optionals enablePython [
    "-DPython3_EXECUTABLE=${lib.getExe python3}" # https://mlir.llvm.org/docs/Bindings/Python/#cmake-variables
    "-DMLIR_PYTHON_INSTALL_DIR=${placeholder "python"}" # See ./patch-python-install-location.patch
  ] ++ lib.optionals enableDocs [
    "-DLLVM_ENABLE_DOXYGEN=ON"
    "-DLLVM_BUILD_DOCS=ON"
  ] ++ lib.optionals enableRunners (
    [
      # TODO: CUDA
      # TODO: ROCm
      "-DMLIR_ENABLE_SPIRV_CPU_RUNNER=ON"
    ] ++ lib.optional enableVulkan "-DMLIR_ENABLE_VULKAN_RUNNER=ON"
  );
  # TODO: specify tablegen binaries explicitly when cross-compiling?

  # # Patch around check for being built native (maybe because not built w/LLVM?)
  # postPatch = lib.optionalString enableRunners ''
  #   for x in **/CMakeLists.txt; do
  #     substituteInPlace "$x" --replace 'if(TARGET ''${LLVM_NATIVE_ARCH})' 'if (1)'
  #   done
  # '';

  # TODO: necessary?
  # postBuild = ''
  #   make ${lib.concatStringsSep " " bins} -j$NIX_BUILD_CORES -l$NIX_BUILD_CORES
  # '';
  # TODO: is this required?
  # install -Dm755 -t $out/bin ${lib.concatMapStringsSep " " (x: "bin/${x}") bins}
  #
  # update: no; `LLVM_BUILD_TOOLS` seems to do the trick

  ninjaFlags = [ "all" ]
    # https://github.com/llvm/mlir-www/blob/d74dafe22d96d4067b741ee9b59a0ab3d02cc6ff/.github/workflows/main.yml#L35
    ++ lib.optionals enableDocs [ "mlir-doc" "doxygen-mlir" ];

  postInstall = ''
    mkdir -p $out/share/vim-plugins/
    cp -r ../utils/vim $out/share/vim-plugins/mlir
    install -Dt $out/share/emacs/site-lisp ../utils/emacs/mlir-mode.el

    moveToOutput src $dev
  '' + lib.optionalString enablePython ''
    ln -s $lib/lib $python/lib # See ./patch-python-install-location.patch
  '' + lib.optionalString enableDocs ''
    mv $out/docs $doc
  '';

  passthru = (lib.optionalAttrs enablePython rec {

    # This is something of a stopgap solution; see:
    #  - https://github.com/stellaraccident/mlir-py-release
    #  - https://github.com/stellaraccident/mlir-py-release/blob/4b068a6d0c794dd812044f7b688ef57b35b3588f/packages/mlir/setup.py
    #  - https://discourse.llvm.org/t/help-needed-installing-and-releasing-python-based-mlir-projects/2131/29

    # Normally packages that also expose python bindings do so under the `out`
    # output at `lib/python-${interpreter-version}/site-packages/<package>`.
    #
    # For the MLIR python bindings we have a `python` output on the actual MLIR
    # package that we then materialize a python package (below) from by creating
    # some symlinks.
    #
    # We break tradition for a few reasons:
    #   - we don't want to force users of the python bindings to incur the
    #     closure size cost of the `out` output of the main MLIR package
    #   - placing python bindings at a different output than `out` doesn't work
    #     so well; some hooks like `python-import-check-hook` assume that the
    #     python module being tested will land in `out` and we want the
    #     propagated python deps to be associated with `python` not `out`
    #   - the MLIR build configuration for the python bindings doesn't follow
    #     the usual conventions anyways; installed python outputs are placed at
    #     `python_packages` instead of the typical `lib/python-/site-packages`.
    #     see: https://mlir.llvm.org/docs/Bindings/Python/#recommended-development-practices
    #     we _can_ adjust the install path for the python bindings to be the
    #     usual install location but making symlinks after the fact seems easier
    #     (don't need to keep CMake's `RELATIVE_INSTALL_ROOT` in sync)
    #
    # These factors make creating another derivation for the python bindings the
    # easier option.
    python-bindings = stdenv.mkDerivation {
      pname = "mlir-python-bindings";
      inherit version;

      # TODO: fix this bit; doesn't get picked up?
      disabled = python3.pythonOlder "3.6"; # https://llvm.org/docs/GettingStarted.html#requirements

      nativeBuildInputs = [ python3 ];
      propagatedBuildInputs = pythonRuntimeDeps;

      unpackPhase = "true";
      installPhase = ''
        installDir="$out/lib/python${python3.pythonVersion}/site-packages/"

        mkdir -p "$installDir"
        ln -s "${mlir.python}/python_packages/mlir_core/mlir" "$installDir/mlir"
      '';

      pythonImportsCheck = lib.optionals enablePython [
        "mlir"
        "mlir.passes" "mlir.dialect" "mlir.execution_engine" "mlir.passmanager"
      ];

      # https://github.com/llvm/llvm-project/blob/5e83a5b4752da6631d79c446f21e5d128b5c5495/mlir/test/python/integration/dialects/linalg/opsrun.py#L1
      #
      # Note: this is a temporary thing; just until we have actual rdeps of the
      # python bindings within nixpkgs to catch breakage
      passthru.tests.linalg-execute = let
        script = fetchurl {
          url = "https://raw.githubusercontent.com/llvm/llvm-project/5e83a5b4752da6631d79c446f21e5d128b5c5495/mlir/test/python/integration/dialects/linalg/opsrun.py";
          hash = "sha256-xFgkBQ0vWeVZH9RBSbhR9FsYOr+Oz1KcEfkf5MDjWk8=";
        };
      in runCommand "linalg-execute-test" {
        preferLocalBuild = false;
        allowSubstitutes = true;

        nativeBuildInputs = [
          (pyPkgs.toPythonModule python-bindings)
        ];
      } ''
        python3 ${script} &> $out
      '';
    };
  }) // {
    # vscode-extension = null; # TODO

    tests = {
      no-python-build = null; # TODO: test that building without python and docs works..
    };
  };

  doCheck = false; # TODO? just hostPlatform == buildPlatform?
  checkTarget = "check-mlir"; # TODO? just unit tests?

  meta = llvm_meta // {
    homepage = "https://mlir.llvm.org";
    description = "Multi-Level Intermediate Representation";
    longDescription = ''
      The MLIR project is a novel approach to building reusable and extensible
      compiler infrastructure.
      MLIR aims to address software fragmentation, improve compilation for
      heterogeneous hardware, significantly reduce the cost of building domain
      specific compilers, and aid in connecting existing compilers together.
    '';
    mainProgram = "mlir-opt";
  };
};
in mlir
