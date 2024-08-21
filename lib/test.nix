{
  lib,
  pyproject-nix,
  poetry2nix,
  pkgs,
}:
let
  inherit (builtins)
    mapAttrs
    substring
    stringLength
    length
    attrNames
    ;
  inherit (lib) mapAttrs' toUpper;

  capitalise = s: toUpper (substring 0 1 s) + (substring 1 (stringLength s) s);

  callTest = path: import path (poetry2nix // { inherit pkgs lib pyproject-nix; });

in
lib.fix (self: {
  metadata2 = callTest ./test_metadata2.nix;
  sources = callTest ./test_sources.nix;
  overlay = callTest ./test_overlay.nix;

  # Yo dawg, I heard you like tests...
  #
  # Check that all exported modules are covered by a test suite with at least one test.
  # TODO: Use addCoverage from nix-unit
  coverage = mapAttrs (
    moduleName:
    mapAttrs' (
      sym: _: {
        name = "test" + capitalise sym;
        value = {
          expected = true;
          expr = self ? ${moduleName}.${sym} && length (attrNames self.${moduleName}.${sym}) >= 1;
        };
      }
    )
  ) poetry2nix;
})
