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
      in
      {
        devShells.default = pkgs.mkShell rec {
          buildInputs = with pkgs; [
            # LuaJIT runtime
            luajit
            # JS tooling for docs
            bun
            # Native libraries (lib/sqlite, lib/compress, etc.)
            sqlite
            zlib
          ];
          LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}:$LD_LIBRARY_PATH";
          shellHook = ''
            export PATH="$PWD/bin:$PATH"
          '';
        };
      }
    );
}
