# Development shell for sparkr NES homebrew project.
#
# Provides:
#   - python3 + Pillow  (for bin/bmp2nes and gen_*.py asset scripts)
#   - cc65 is NOT managed here — install via Homebrew: `brew install cc65`
#
# Usage:
#   nix-shell          # drops into a shell with the env active
#   nix-shell --run make      # build without entering an interactive shell
#   nix-shell --run 'make mesen'
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "sparkr-dev";

  packages = [
    (pkgs.python3.withPackages (ps: [
      ps.pillow
    ]))
    pkgs.cc65
  ];

  # Point the Makefile at the nix-provided cc65 binaries.
  # cc65 installs ca65/ld65 directly into bin/ with no subdirectory,
  # so CC65DIR is the store path and CC65BINDIR stays $(CC65DIR)/bin.
  shellHook = ''
    export CC65DIR=${pkgs.cc65}
    echo "sparkr dev shell — python3 + Pillow + cc65 ready"
    echo "  CC65DIR=$CC65DIR"
  '';
}
