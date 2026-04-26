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
        extraInputs = if hasVendored then [] else [ pkgs.luajit ];
      in
      {
        devShells.default = pkgs.mkShell rec {
          buildInputs = with pkgs; [
            # JS tooling for docs (until lib/markdown exists and we can self-host)
            bun
            # Native libraries (lib/sqlite, lib/compress, etc.)
            sqlite
            zlib
          ] ++ extraInputs;
          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH";
          shellHook = ''
            export PATH="$PWD/bin:$PATH"
          '';
        };
      }
    );
}
