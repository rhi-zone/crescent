{
  description = "crescent - Comprehensive LuaJIT ecosystem — stdlib, typechecker, package manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        # Platforms with a vendored LuaJIT binary in bin/.
        # All others fall back to nixpkgs luajit.
        vendoredPlatforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
        hasVendored = builtins.elem system vendoredPlatforms;
        # On vendoredPlatforms, dep/libsqlite3-* and dep/libz-* are also
        # shipped, so system sqlite/zlib follow the same conditional as luajit.
        extraInputs = if hasVendored then [] else [ pkgs.luajit pkgs.sqlite pkgs.zlib ];

        # PUC-Lua interpreters 5.1–5.4, exposed under stable `lua5.x` names, for
        # the lib/sem Loop-α DIFFERENTIAL HARNESS ONLY (validating the executable
        # formal semantics against each real Lua version, per docs/typechecker-
        # formal-semantics.md §2). These are CONTRIBUTOR / CI TOOLING — they are
        # NEVER a runtime dependency: `bin/cr` and `bin/cr test` must run on a bare
        # clone with ONLY the vendored LuaJIT, and the harness SKIPS any absent
        # version. LuaJIT stays the sole vendored/runtime interpreter.
        #
        # nixpkgs installs every PUC interpreter as plain `lua`, which would
        # collide on PATH; symlink each to its versioned `lua5.x` name so the
        # harness's `command -v lua5.3` probe resolves the right one.
        pucBin = pkgs.runCommand "cr-puc-lua" {} ''
          mkdir -p $out/bin
          ln -s ${pkgs.lua5_1}/bin/lua $out/bin/lua5.1
          ln -s ${pkgs.lua5_2}/bin/lua $out/bin/lua5.2
          ln -s ${pkgs.lua5_3}/bin/lua $out/bin/lua5.3
          ln -s ${pkgs.lua5_4}/bin/lua $out/bin/lua5.4
        '';
      in
      {
        devShells.default = pkgs.mkShell rec {
          buildInputs = with pkgs; [
            # JS tooling for docs (until lib/markdown exists and we can self-host)
            bun
            # PUC Lua 5.1–5.4 for the lib/sem Loop-α differential harness ONLY
            # (contributor/CI tooling; NOT a runtime dependency — see pucBin above).
            pucBin
            # Coq/Rocq proof assistant for the mechanized type-system kernel in
            # proof/ (correct-by-construction subtype metatheory). QuickChick is
            # certified property-based testing for the same kernel. These are
            # STRICTLY build-time / CI proof tooling — the shipped checker
            # (`bin/cr`) and `bin/cr test` have NO dependency on them and run on a
            # bare clone with only the vendored LuaJIT. See docs/proof-kernel.md.
            coq
            coqPackages.QuickChick
            # Browser binaries for playwright-driven UI screenshots/tests.
            playwright-driver.browsers
            # Autotools for regenerating dep/libressl's configure/Makefile.in
            # after a source-level patch to configure.ac or Makefile.am.* (see
            # dep/libressl/patches/0003). CONTRIBUTOR/CI TOOLING ONLY: nothing
            # shipped needs them, and `bin/cr test` never invokes them.
            #
            # These versions are not free-floating -- they are pinned by what
            # generated the checked-in files (`configure` says autoconf 2.72,
            # `aclocal.m4` says aclocal 1.18.1). nixpkgs at the current lock
            # supplies exactly those, so regeneration is a no-op apart from the
            # intended change; a mismatch here would show up as generated-file
            # drift in the diff.
            autoconf   # 2.72
            automake   # 1.18.1
            # NO libtool here, deliberately. dep/libressl vendors libtool 2.4.2
            # macros (m4/libtool.m4, ltversion.m4) and a matching ltmain.sh, and
            # patches 0001/0002 edit those 2.4.2 macros in place. Regeneration
            # runs aclocal/autoconf/automake ONLY -- never libtoolize, never
            # `autoreconf -i`/`-f` -- so the 2.4.2 files are left untouched.
            # nixpkgs' libtool is 2.5.4; letting libtoolize run would overwrite
            # them with 2.5.4, invalidating both patches (and ltmain.sh checks
            # package_revision against macro_revision, so a half-swap fails
            # loudly rather than silently).
          ] ++ extraInputs;
          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH";
          shellHook = ''
            export PATH="$PWD/bin:$PATH"
            export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
          '';
        };
      }
    );
}
