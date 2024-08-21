{
  lib,
  pyproject-nix,
  sources,
  metadata2,
  ...
}:

let
  inherit (pyproject-nix.lib.pep508) mkEnviron;
  inherit (pyproject-nix.lib) pep621;
  inherit (lib)
    head
    splitVersion
    isBool
    throwIf
    mapAttrs
    ;

in
{
  # Create an overlay from a loaded pyproject.nix Poetry project.
  mkOverlay =
    {
      # Project loaded using pyproject-nix.lib.project.loadPoetryPyproject
      project,
      # Whether to prefer binary wheels over sdists
      preferWheels,
      # Which extras to enable for project
      extras ? [ ],
    }:
    let
      inherit (project.poetryLock) metadata;

      # Check lock metadata compatibility
      lockVersion = splitVersion metadata.lock-version;

      resolveDependencies = metadata2.resolveDependencies { inherit project; };

      mkPackage = metadata2.mkPackage {
        inherit project;
        # Get configured PyPI mirrors from pyproject.toml
        sources = sources.mkSources { inherit project; };
      };

    in

    # Validate inputs
    assert isBool preferWheels;
    throwIf (project.poetryLock == null)
      ''
        Project is not a pyproject.nix Poetry project.
        Load using pyproject-nix.lib.project.loadPoetryPyproject.
      ''
      throwIf
      (head lockVersion != "2")
      ''
        Poetry2nix is only compatible with poetry.lock metadata version 2.
      ''

      (
        final: _prev:
        let
          inherit (final) python callPackage;

          # TODO: Environment customisation
          environ = mkEnviron python;

          resolved = resolveDependencies {
            dependencies = pep621.filterDependencies {
              inherit (project) dependencies;
              inherit extras environ;
            };
            inherit environ;
          };
        in
        mapAttrs (_: package: callPackage (mkPackage package) { }) resolved
      );
}
