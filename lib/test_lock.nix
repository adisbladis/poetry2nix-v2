{ lib, lock, pyproject-nix, sources, pkgs, ... }:

let

  mkFixture = path: {
    pyproject = lib.importTOML (path + "/pyproject.toml");
    lock = lib.importTOML (path + "/poetry.lock");
  };

  fixtures = {
    trivial = mkFixture ./fixtures/trivial;
    kitchen-sink = mkFixture ./fixtures/kitchen-sink/a;
  };

  findPkg = pkgName: fixture: lib.findFirst (pkg: pkg.name == pkgName) (throw "not found") fixture.lock.package;

in

{
  fetchPoetryPackage =
    let
      pyproject = lib.importTOML ./fixtures/kitchen-sink/a/pyproject.toml;
      poetryLock = lib.importTOML ./fixtures/kitchen-sink/a/poetry.lock;
      projectRoot = ./fixtures/kitchen-sink/a;
      fetchPoetryPackage = pkgs.callPackage lock.fetchPoetryPackage { };
      findPackage = name: lib.findFirst (pkg: pkg.name == name) (throw "package '${name} not found") poetryLock.package;
    in
    {
      testGit = {
        expr =
          let
            src = fetchPoetryPackage {
              inherit pyproject projectRoot;
              package = findPackage "pip";
              sources = { };
            };
          in
          assert lib.hasAttr "outPath" src;
          { inherit (src) ref allRefs submodules rev; };
        expected = {
          allRefs = true;
          ref = "refs/tags/20.3.1";
          rev = "f94a429e17b450ac2d3432f46492416ac2cf58ad";
          submodules = true;
        };
      };

      testPathSdist = {
        expr =
          let
            src = fetchPoetryPackage {
              inherit pyproject projectRoot;
              package = findPackage "attrs";
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
        expr = (fetchPoetryPackage {
          inherit pyproject projectRoot;
          package = findPackage "Arpeggio";
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
            src = (fetchPoetryPackage {
              inherit pyproject projectRoot;
              package = findPackage "requests";
              filename = "requests-2.32.3.tar.gz";
              sources = sources.mkSources { project = { }; }; # Dummy empty project
            }).passthru;
          in
          src;
        expected = { };
      };
    };

  # Test fetchPoetryPackage using a variety of source configurations
  sources = let
    fetchPoetryPackage = pkgs.callPackage lock.fetchPoetryPackage {
      fetchPypiLegacy = lib.id;
    };

    mkTest = {
      projectRoot
      , name
      , filename
    }: let
      project = pyproject-nix.lib.project.loadPoetryPyproject {
        pyproject = lib.importTOML (projectRoot + "/pyproject.toml");
      };
      poetryLock = lib.importTOML  (projectRoot + "/poetry.lock");

      in fetchPoetryPackage {
        inherit (project) pyproject;
        inherit projectRoot filename;
        package = lib.findFirst (pkg: pkg.name == name) (throw "package '${name} not found") poetryLock.package;
        sources = sources.mkSources { inherit project; };
      };

    expr' = {
      name = "arpeggio";
      filename = "Arpeggio-2.0.2.tar.gz";
    };

    expected' = {
      file = "Arpeggio-2.0.2.tar.gz";
      hash = "sha256:c790b2b06e226d2dd468e4fbfb5b7f506cec66416031fde1441cf1de2a0ba700";
      pname = "arpeggio";
    };

  in {
    testExplicit = {
      expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/explicit; });
      expected = expected' // {
        url = "https://pypi.org/simple";
      };
    };

    testSupplemental = {
      expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/supplemental; });
      expected = expected' // {
        urls = [ "https://pypi.org/simple" "https://foo.bar/simple/" ];
      };
    };

    testPrimary = {
      expr = mkTest (expr' // { projectRoot = ./fixtures/package-sources/primary; });
      expected = expected' // {
        urls = [ "https://foo.bar/simple/" ];
      };
    };
  };


  partitionFiles = {
    testSimple = {
      expr = lock.partitionFiles (findPkg "arpeggio" fixtures.trivial).files;
      expected = {
        eggs = [ ];
        others = [ ];
        sdists = [
          {
            file = "Arpeggio-2.0.2.tar.gz";
            hash = "sha256:c790b2b06e226d2dd468e4fbfb5b7f506cec66416031fde1441cf1de2a0ba700";
          }
        ];
        wheels = [
          {
            file = "Arpeggio-2.0.2-py2.py3-none-any.whl";
            hash = "sha256:f7c8ae4f4056a89e020c24c7202ac8df3e2bc84e416746f20b0da35bb1de0250";
          }
        ];
      };
    };
  };

  mkPackage =
    let
      project = {
        pyproject = { };
      }; # Dummy empty project for tests

      python = pkgs.python312;

      mkPackage' = lock.mkPackage { inherit project; preferWheels = false; };
      mkPackage = pkg: let
        attrs = python.pkgs.callPackage (mkPackage' pkg) {
          buildPythonPackage = lib.id;

          __poetry2nix = {
            fetchPoetryPackage = pkgs.callPackage lock.fetchPoetryPackage { };
            environ = pyproject-nix.lib.pep508.mkEnviron python;
            pyVersion = pyproject-nix.lib.pep440.parseVersion python.version;
            sources = sources.mkSources { inherit project; };
          };
        };

        cleaned = removeAttrs attrs [ "override" "overrideDerivation" ];
      in
        cleaned
        // {
          # Just extract names of dependencies for equality checking
          dependencies = map (dep: dep.pname) attrs.dependencies;
          optional-dependencies = lib.mapAttrs (_: extras: map (drv: drv.pname) extras) attrs.optional-dependencies;

          # Only get URLs from src
          src = attrs.src.passthru;
        };

    in
    {
      # A simple package with only optional dependencies
      testSimple = {
        expr = mkPackage (findPkg "arpeggio" fixtures.trivial);
        expected = {
          pname = "arpeggio";
          src = { };
          dependencies = [ ];
          version = "2.0.2";
          format = "pyproject";
          optional-dependencies = {
            dev = [ "mike" "mkdocs" "twine" "wheel" ];
            test = [ "coverage" "coveralls" "flake8" "pytest" ];
          };
          meta = {
            description = "Packrat parser interpreter";
          };
        };
      };

      # A package with dependencies
      testPackage = {
        expr = mkPackage (findPkg "requests" fixtures.kitchen-sink);
        expected = {
          pname = "requests";
          src = { };
          version = "2.32.3";
          format = "pyproject";
          dependencies = [ "certifi" "charset-normalizer" "idna" "urllib3" ];
          optional-dependencies = {
            socks = [ "pysocks" ];
            use-chardet-on-py3 = [ "chardet" ];
          };
          meta = {
            description = "Python HTTP for Humans.";
          };
        };
      };

    };
}
