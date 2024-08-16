{
  lib,
  pyproject-nix,
  sources,
  ...
}:

let
  implicitPypi = {
    name = "pypi";
    url = "https://pypi.org/simple";
  };

in
{
  mkSources =
    let
      mkSources =
        path:
        sources.mkSources {
          project = pyproject-nix.lib.project.loadPoetryPyproject {
            pyproject = lib.importTOML (path + "/pyproject.toml");
          };
        };
    in
    {
      testImplicitPypi = {
        expr = mkSources ./fixtures/trivial;
        expected = {
          sources.pypi = implicitPypi;
          order = [ "pypi" ];
        };
      };

      testExplicit = {
        expr = mkSources ./fixtures/package-sources/explicit;
        expected = {
          sources = {
            pypi = implicitPypi;
            foo = {
              name = "foo";
              priority = "explicit";
              url = "https://pypi.org/simple";
            };
          };
          order = [ "pypi" ];
        };
      };

      testPrimary = {
        expr = mkSources ./fixtures/package-sources/supplemental;
        expected = {
          sources = {
            pypi = implicitPypi;
            foo = {
              name = "foo";
              priority = "supplemental";
              url = "https://foo.bar/simple/";
            };
          };
          order = [
            "pypi"
            "foo"
          ];
        };
      };

      testSupplemental = {
        expr = mkSources ./fixtures/package-sources/supplemental;
        expected = {
          sources = {
            pypi = implicitPypi;
            foo = {
              name = "foo";
              priority = "supplemental";
              url = "https://foo.bar/simple/";
            };
          };
          order = [
            "pypi"
            "foo"
          ];
        };
      };
    };
}
