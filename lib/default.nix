{ lib
, pyproject-nix
,
}:
let
  inherit (builtins) mapAttrs;
  inherit (lib) fix;
in
fix (self:
mapAttrs (_: path: import path ({ inherit lib pyproject-nix; } // self)) {
  lock = ./lock.nix;
  sources = ./sources.nix;
})
