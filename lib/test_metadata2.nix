{
  lib,
  metadata2,
  pyproject-nix,
  sources,
  pkgs,
  ...
}:

let
  inherit (pyproject-nix.lib) pep508 pep621;
  inherit (pyproject-nix.lib.project) loadPoetryPyproject;

  mkFixture = path: loadPoetryPyproject { projectRoot = path; };

  fixtures = {
    trivial = mkFixture ./fixtures/trivial;
    simple = mkFixture ./fixtures/simple;
    kitchen-sink = mkFixture ./fixtures/kitchen-sink/a;
    withMarker = mkFixture ./fixtures/with-marker;
    multiChoiceNestedDependent = mkFixture ./fixtures/multi-choice-nested/dependent-package;
  };

  findPkg =
    pkgName: fixture:
    lib.findFirst (pkg: pkg.name == pkgName) (throw "not found") fixture.poetryLock.package;

  # Expected saved as JSON files
  expected =
    let
      expected' = lib.mapAttrs (n: _: lib.importJSON (./. + "/expected/${n}")) (
        lib.filterAttrs (filename: type: lib.hasSuffix ".json" filename && type == "regular") (
          builtins.readDir ./expected
        )
      );
    in
    test: expected'.${"${test}.json"};

in

{
  resolveDependencies = {
    testSimple =
      let
        environ = pep508.mkEnviron pkgs.python312;
        project = fixtures.simple;
      in
      {
        expr = metadata2.resolveDependencies { inherit project; } {
          inherit environ;
          dependencies = pep621.filterDependencies {
            inherit (project) dependencies;
            inherit environ;
            extras = [ ];
          };
        };
        expected = expected "metadata2.resolveDependencies.testSimple";
      };

    testWithMarker =
      let
        environ = pep508.mkEnviron pkgs.python312;
        project = fixtures.withMarker;
      in
      {
        expr = metadata2.resolveDependencies { inherit project; } {
          inherit environ;
          dependencies = pep621.filterDependencies {
            inherit (project) dependencies;
            inherit environ;
            extras = [ ];
          };
        };
        expected = expected "metadata2.resolveDependencies.testWithMarker";
      };

    testMultiChoiceNestedDependent =
      let
        environ = pep508.mkEnviron pkgs.python310;
        project = fixtures.multiChoiceNestedDependent;
      in
      {
        expr = metadata2.resolveDependencies { inherit project; } {
          inherit environ;
          dependencies = pep621.filterDependencies {
            inherit (project) dependencies;
            inherit environ;
            extras = [ ];
          };
        };
        expected = expected "metadata2.resolveDependencies.testMultiChoiceNestedDependent";
      };

  };

  filterPackage =
    let
      environ = pep508.mkEnviron pkgs.python312;
    in
    {
      testSimple = {
        expr = metadata2.filterPackage environ (
          metadata2.parsePackage (findPkg "requests" fixtures.simple)
        );
        expected = expected "metadata2.filterPackage.testSimple";
      };

      testWithMarker = {
        expr = metadata2.filterPackage environ (
          metadata2.parsePackage (findPkg "pytest" fixtures.withMarker)
        );
        expected = expected "metadata2.filterPackage.testWithMarker";
      };
    };

  fetchPackage =
    let
      poetryLock = lib.importTOML ./fixtures/kitchen-sink/a/poetry.lock;
      projectRoot = ./fixtures/kitchen-sink/a;
      fetchPackage =
        args:
        metadata2.fetchPackage (
          args
          // {
            inherit (pkgs) fetchurl fetchPypiLegacy;
            inherit projectRoot;
          }
        );
      findPackage =
        name: lib.findFirst (pkg: pkg.name == name) (throw "package '${name} not found") poetryLock.package;
    in
    {
      testGit = {
        expr =
          let
            src = fetchPackage {
              package = metadata2.parsePackage (findPackage "pip");
              sources = { };
            };
          in
          assert lib.hasAttr "outPath" src;
          {
            inherit (src) submodules rev;
          };
        expected = {
          rev = "f94a429e17b450ac2d3432f46492416ac2cf58ad";
          submodules = true;
        };
      };

      testPathSdist = {
        expr =
          let
            src = fetchPackage {
              package = metadata2.parsePackage (findPackage "attrs");
              filename = "attrs-23.1.0.tar.gz";
              sources = { };
            };
          in
          {
            isStorePath = lib.isStorePath "${src}";
            hasSuffix = lib.hasSuffix "attrs-23.1.0.tar.gz" "${src}";
          };
        expected = {
          isStorePath = true;
          hasSuffix = true;
        };
      };

      testURL = {
        expr =
          (fetchPackage {
            package = metadata2.parsePackage (findPackage "Arpeggio");
            filename = "Arpeggio-2.0.2-py2.py3-none-any.whl";
            sources = { };
          }).passthru;
        expected = {
          url = "https://files.pythonhosted.org/packages/f7/4f/d28bf30a19d4649b40b501d531b44e73afada99044df100380fd9567e92f/Arpeggio-2.0.2-py2.py3-none-any.whl";
        };
      };

      testFetchFromLegacy = {
        expr =
          let
            src =
              (fetchPackage {
                package = metadata2.parsePackage (findPackage "requests");
                filename = "requests-2.32.3.tar.gz";
                sources = sources.mkSources { project = { }; }; # Dummy empty project
              }).passthru;
          in
          src;
        expected = { };
      };
    };

  # Test fetchPackage using a variety of source configurations
  sources =
    let
      fetchPackage =
        args:
        metadata2.fetchPackage (
          args
          // {
            fetchPypiLegacy = lib.id;
            fetchurl = lib.id;
          }
        );

      mkTest =
        {
          projectRoot,
          name,
          filename,
        }:
        let
          project = pyproject-nix.lib.project.loadPoetryPyproject {
            pyproject = lib.importTOML (projectRoot + "/pyproject.toml");
          };
          poetryLock = lib.importTOML (projectRoot + "/poetry.lock");

        in
        fetchPackage {
          inherit projectRoot filename;
          package = metadata2.parsePackage (
            lib.findFirst (pkg: pkg.name == name) (throw "package '${name} not found") poetryLock.package
          );
          sources = sources.mkSources { inherit project; };
        };

      expr' = {
        name = "arpeggio";
        filename = "Arpeggio-2.0.2.tar.gz";
      };

    in
    {
      testExplicit = {
        expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/explicit; });
        expected = expected "sources.testExplicit";
      };

      testSupplemental = {
        expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/supplemental; });
        expected = expected "sources.testSupplemental";
      };

      testPrimary = {
        expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/primary; });
        expected = expected "sources.testPrimary";
      };
    };

  partitionFiles = {
    testSimple = {
      expr = metadata2.partitionFiles (findPkg "arpeggio" fixtures.trivial).files;
      expected = expected "partitionFiles.testSimple";
    };
  };

  parsePackage =
    let
      testPkg = pkgName: (metadata2.parsePackage (findPkg pkgName fixtures.kitchen-sink));
    in
    {
      testPackage = {
        expr = testPkg "requests";
        expected = expected "parsePackage.testPackage";
      };

      testMultiChoicePackage = {
        expr = metadata2.parsePackage (findPkg "multi-choice-package" fixtures.multiChoiceNestedDependent);
        expected = expected "parsePackage.testMultiChoicePackage";
      };

      testWithMarker = {
        expr = metadata2.parsePackage (findPkg "pytest" fixtures.withMarker);
        expected = expected "parsePackage.testWithMarker";
      };

      testExtras = {
        expr = testPkg "urllib3";
        expected = expected "parsePackage.testExtras";
      };

      testURLSource = {
        expr = testPkg "Arpeggio";
        expected = expected "parsePackage.testURLSource";
      };
    };

  mkPackage =
    let
      project = {
        pyproject = { };
      }; # Dummy empty project for tests

      python = pkgs.python312;

      mkPackage =
        pkg:
        let
          attrs = python.pkgs.callPackage (metadata2.mkPackage {
            sources = sources.mkSources { inherit project; };
            inherit project;
          } (metadata2.parsePackage pkg)) { buildPythonPackage = lib.id; };

          cleaned = removeAttrs attrs [
            "override"
            "overrideDerivation"
          ];
        in
        cleaned
        // {
          # Just extract names of dependencies for equality checking
          dependencies = map (dep: dep.pname) attrs.dependencies;
          optional-dependencies = lib.mapAttrs (
            _: extras: map (drv: drv.pname) extras
          ) attrs.optional-dependencies;

          # Only get URLs from src
          src = attrs.src.passthru;
        };

    in
    {
      # A simple package with only optional dependencies
      testSimple = {
        expr = mkPackage (findPkg "arpeggio" fixtures.trivial);
        expected = expected "mkPackage.testSimple";
      };

      # A package with dependencies
      testPackage = {
        expr = mkPackage (findPkg "requests" fixtures.kitchen-sink);
        expected = expected "mkPackage.testPackage";
      };

      # A package with markers
      testWithMarker = {
        expr = mkPackage (findPkg "pytest" fixtures.withMarker);
        expected = expected "mkPackage.testWithMarker";
      };
    };
}
