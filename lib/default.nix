{ lib, pyproject-nix }:
let
  inherit (builtins) mapAttrs;
  inherit (lib) fix;
in
fix (
  self:
  mapAttrs (_: path: import path ({ inherit lib pyproject-nix; } // self)) {
    metadata2 = ./metadata2.nix;
    sources = ./sources.nix;
    overlay = ./overlay.nix;
  }
)
