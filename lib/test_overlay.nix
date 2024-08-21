{
  pyproject-nix,
  overlay,
  pkgs,
  ...
}:

let
  inherit (pyproject-nix.lib.project) loadPoetryPyproject;

  projects = {
    trivial = loadPoetryPyproject { projectRoot = ./fixtures/trivial; };
  };

in

{
  mkOverlay =
    let
      testPython = pkgs.python312;
    in
    {
      testTrivialSdist = {
        expr =
          let
            overlay' = overlay.mkOverlay {
              project = projects.trivial;
              preferWheels = false;
            };

            python = testPython.override {
              self = python;
              packageOverrides = overlay';
            };

          in
          {
            inherit (python.pkgs.arpeggio) pname version;
            inherit (python.pkgs.arpeggio.meta) description;
          };
        expected = {
          pname = "arpeggio";
          version = "2.0.2";
          description = "Packrat parser interpreter";
        };
      };
    };
}
