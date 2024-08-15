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
  fetchPackage =
    let
      poetryLock = lib.importTOML ./fixtures/kitchen-sink/a/poetry.lock;
      projectRoot = ./fixtures/kitchen-sink/a;
      fetchPackage = args: lock.fetchPackage (args // { inherit (pkgs) fetchurl fetchPypiLegacy; inherit projectRoot; });
      findPackage = name: lib.findFirst (pkg: pkg.name == name) (throw "package '${name} not found") poetryLock.package;
    in
    {
      testGit = {
        expr =
          let
            src = fetchPackage {
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
            src = fetchPackage {
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
        expr = (fetchPackage {
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
            src = (fetchPackage {
              package = findPackage "requests";
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
      fetchPackage = args: lock.fetchPackage (args // {
        fetchPypiLegacy = lib.id;
        fetchurl = lib.id;
      });

      mkTest =
        { projectRoot
        , name
        , filename
        }:
        let
          project = pyproject-nix.lib.project.loadPoetryPyproject {
            pyproject = lib.importTOML (projectRoot + "/pyproject.toml");
          };
          poetryLock = lib.importTOML (projectRoot + "/poetry.lock");

        in
        fetchPackage {
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

    in
    {
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

  parsePackage =
    let
      testPkg = pkgName: lock.parsePackage (findPkg pkgName fixtures.kitchen-sink);
    in
    {
      testPackage = {
        expr = testPkg "requests";
        expected = { dependencies = { certifi = ">=2017.4.17"; charset-normalizer = ">=2,<4"; idna = ">=2.5,<4"; urllib3 = ">=1.21.1,<3"; }; description = "Python HTTP for Humans."; extras = { socks = [{ conditions = [ ]; extras = [ ]; markers = null; name = "pysocks"; url = null; }]; use-chardet-on-py3 = [{ conditions = [ ]; extras = [ ]; markers = null; name = "chardet"; url = null; }]; }; files = [{ file = "requests-2.32.3-py3-none-any.whl"; hash = "sha256:70761cfe03c773ceb22aa2f671b4757976145175cdfca038c02654d061d6dcc6"; } { file = "requests-2.32.3.tar.gz"; hash = "sha256:55365417734eb18255590a9ff9eb97e9e1da868d4ccd6402399eaf68af20a760"; }]; name = "requests"; optional = false; python-versions = [{ op = ">="; version = { dev = null; epoch = 0; local = null; post = null; pre = null; release = [ 3 8 ]; }; }]; source = { }; version = "2.32.3"; version' = { dev = null; epoch = 0; local = null; post = null; pre = null; release = [ 2 32 3 ]; }; };
      };

      testURLSource = {
        expr = testPkg "Arpeggio";
        expected = { dependencies = { }; description = "Packrat parser interpreter"; extras = { dev = [{ conditions = [ ]; extras = [ ]; markers = null; name = "mike"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "mkdocs"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "twine"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "wheel"; url = null; }]; test = [{ conditions = [ ]; extras = [ ]; markers = null; name = "coverage"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "coveralls"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "flake8"; url = null; } { conditions = [ ]; extras = [ ]; markers = null; name = "pytest"; url = null; }]; }; files = [{ file = "Arpeggio-2.0.2-py2.py3-none-any.whl"; hash = "sha256:f7c8ae4f4056a89e020c24c7202ac8df3e2bc84e416746f20b0da35bb1de0250"; }]; name = "Arpeggio"; optional = false; python-versions = [{ op = ""; version = { dev = null; epoch = 0; local = null; post = null; pre = null; release = [ "*" ]; }; }]; source = { type = "url"; url = "https://files.pythonhosted.org/packages/f7/4f/d28bf30a19d4649b40b501d531b44e73afada99044df100380fd9567e92f/Arpeggio-2.0.2-py2.py3-none-any.whl"; }; version = "2.0.2"; version' = { dev = null; epoch = 0; local = null; post = null; pre = null; release = [ 2 0 2 ]; }; };
      };
    };

  mkPackage =
    let
      project = {
        pyproject = { };
      }; # Dummy empty project for tests

      python = pkgs.python312;

      mkPackage = pkg:
        let
          attrs = python.pkgs.callPackage (lock.mkPackage (lock.parsePackage pkg)) {
            buildPythonPackage = lib.id;

            __poetry2nix = {
              environ = pyproject-nix.lib.pep508.mkEnviron python;
              pyVersion = pyproject-nix.lib.pep440.parseVersion python.version;
              preferWheels = false;
              sources = sources.mkSources { inherit project; };
              inherit project;
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
