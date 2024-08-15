{ lib, pyproject-nix, ... }:

let
  inherit (builtins) head nixVersion;
  inherit (lib) length listToAttrs nameValuePair optionalAttrs versionAtLeast mapAttrs concatMap mapAttrsToList concatLists hasPrefix;

  inherit (pyproject-nix.lib) pypa pep440 pep508;
  libeggs = pyproject-nix.lib.eggs;

  # Select the best compatible wheel from a list of wheels
  selectWheels = wheels: python:
    let
      # Filter wheels based on interpreter
      compatibleWheels = pypa.selectWheels python.stdenv.targetPlatform python (map (fileEntry: pypa.parseWheelFileName fileEntry.file) wheels);
    in
    map (wheel: wheel.filename) compatibleWheels;

  # Select the best compatible egg from a list of eggs
  selectEggs = eggs': python: map (egg: egg.filename) (libeggs.selectEggs python (map (egg: libeggs.parseEggFileName egg.file) eggs'));

  optionalHead = list: if length list > 0 then head list else null;

  # Poetry extras contains non-pep508 version bounds that looks like `attrs (>=19.2)`
  # We need to strip that before passing them on to pep508.parseString
  parseExtra = let
    matchExtra = builtins.match "(.+) .+";
  in extra: pep508.parseString (let m = matchExtra extra; in if m != null then head m else extra);

  parseExtras = lib.mapAttrs (_: extras: map parseExtra extras);

in

lib.fix (self: {

  fetchPackage =
    { fetchurl, fetchPypiLegacy }:
    {
      # The specific package segment from pdm.lock
      package
    , # Project root path used for local file/directory sources
      projectRoot
    , # Filename for which to invoke fetcher
      filename ? throw "Missing argument filename"
    , # Parsed pyproject.toml contents
      pyproject
    , # PyPI sources as extracted from pyproject.toml
      sources
    }:
    let
      # Group list of files by their filename into an attrset
      filesByFileName = listToAttrs (map (file: nameValuePair file.file file) package.files);
      file = filesByFileName.${filename} or (throw "Filename '${filename}' not present in package");

      # Get list of URLs from sources
      urls = map (name: sources.sources.${name}.url) sources.order;

      sourceType = package.source.type or "";
      inherit (package) source;

    in
    if sourceType == "git" then
      (
        builtins.fetchGit
          {
            inherit (source) url;
            rev = source.resolved_reference;
          }
        // optionalAttrs (source ? reference) {
          ref = "refs/tags/${source.reference}";
        }
        // optionalAttrs (versionAtLeast nixVersion "2.4") {
          allRefs = true;
          submodules = true;
        }
      )
    else if sourceType == "url" then
      (
        fetchurl {
          url = assert (baseNameOf source.url) == filename; source.url;
          inherit (file) hash;
        }
      )
    else if sourceType == "file" then
      {
        outPath = projectRoot + "/${source.url}";
      }
    else if sourceType == "legacy" then  # Explicit source
      (fetchPypiLegacy {
        pname = package.name;
        inherit (file) file hash;
        url = sources.sources.${source.reference}.url;
      })
    else
      (fetchPypiLegacy {
        pname = package.name;
        inherit (file) file hash;
        inherit urls;
      });

  partitionFiles =
    # List of files from poetry.lock -> package segment
    files:
    let
      wheels = lib.lists.partition (f: pypa.isWheelFileName f.file) files;
      sdists = lib.lists.partition (f: pypa.isSdistFileName f.file) wheels.wrong;
      eggs = lib.lists.partition (f: libeggs.isEggFileName f.file) sdists.wrong;
    in
    {
      sdists = sdists.right;
      wheels = wheels.right;
      eggs = eggs.right;
      others = eggs.wrong;
    };

  /*
    Parse a single package from poetry.lock
  */
  parsePackage =
    let
      # Poetry extras contains non-pep508 version bounds that looks like `attrs (>=19.2)`
      # We need to strip that before passing them on to pep508.parseString.
      # TODO: Actually parse version bounds too (do we need to?).
      parseExtra = let
        matchExtra = builtins.match "(.+) .+";
      in extra: pep508.parseString (let m = matchExtra extra; in if m != null then head m else extra);
    in
    { name
    , version
    , dependencies ? { }
    , description ? ""
    , optional ? false
    , files ? [ ]
    , extras ? { }
    , python-versions ? "*"
    , source ? { }
    }@package:
    {
      inherit name description optional files source;
      version = pep440.parseVersion version;
      dependencies = dependencies;
      extras = mapAttrs (_: extras: map parseExtra extras) extras;
      python-versions = pep440.parseVersionConds python-versions;
    };

  mkPackage =
    {
      # Project as returned by pyproject.lib.project.loadPoetryPyProject
      project
    }:
    # Package segment
    { name
    , version
    , dependencies ? { }
    , description ? ""  # deadnix: skip
    , optional ? false  # deadnix: skip
    , files ? [ ]  # deadnix: skip
    , extras ? { }  # deadnix: skip
    , python-versions ? "*"  # deadnix: skip
    }@package:
    let
      inherit (self.partitionFiles files) wheels sdists eggs others;
      extras' = parseExtras extras;

    in
    { python
    , stdenv
    , buildPythonPackage
    , pythonPackages
    , wheelUnpackHook
    , pypaInstallHook
    , autoPatchelfHook
    , pythonManylinuxPackages
    , __poetry2nix
    , # Whether to prefer prebuilt binary wheels over sdists
      preferWheel ? __poetry2nix.preferWheels
    }:
    let
      # Select filename based on sdist/wheel preference order.
      filenames =
        let
          selectedWheels = selectWheels wheels python;
          selectedSdists = map (file: file.file) sdists;
        in
        (
          if preferWheel then selectedWheels ++ selectedSdists
          else selectedSdists ++ selectedWheels
        ) ++ selectEggs eggs python ++ map (file: file.file) others;

      filename = optionalHead filenames;

      format =
        if filename == null || pypa.isSdistFileName filename then "pyproject"
        else if pypa.isWheelFileName filename then "wheel"
        else if libeggs.isEggFileName filename then "egg"
        else throw "Could not infer format from filename '${filename}'";

      src = __poetry2nix.fetchPackage {
        inherit (project) pyproject projectRoot;
        inherit package filename;
        inherit (__poetry2nix) sources;
      };

      # Get an extra + it's nested list of extras
      # Example: build[virtualenv] needs to pull in build, but also build.optional-dependencies.virtualenv
      getExtra = extra: let
        dep = pythonPackages.${extra.name};
      in [ dep ] ++ map (extraName: dep.optional-dependencies.${extraName}) extra.extras;

    in
    buildPythonPackage ({
      pname = name;
      inherit version src format;

      dependencies = concatLists (mapAttrsToList (name: spec: let
        dep = pythonPackages.${name};
        extras = spec.extras or [ ];
      in [dep] ++ map (extraName: dep.optional-dependencies.${extraName}) extras) dependencies);

      optional-dependencies = mapAttrs (_: extras: concatMap getExtra extras) extras';

      meta = {
        inherit description;
      };
    } // optionalAttrs (format == "wheel") {
      # Don't strip prebuilt wheels
      dontStrip = true;

      # Add wheel utils
      nativeBuildInputs =
        [ wheelUnpackHook pypaInstallHook ]
          ++ lib.optional stdenv.isLinux autoPatchelfHook
      ;

      buildInputs =
        # Add manylinux platform dependencies.
        lib.optionals (stdenv.isLinux && stdenv.hostPlatform.libc == "glibc") (lib.unique (lib.flatten (
          map
            (tag: (
              if hasPrefix "manylinux1" tag then pythonManylinuxPackages.manylinux1
              else if hasPrefix "manylinux2010" tag then pythonManylinuxPackages.manylinux2010
              else if hasPrefix "manylinux2014" tag then pythonManylinuxPackages.manylinux2014
              else if hasPrefix "manylinux_" tag then pythonManylinuxPackages.manylinux2014
              else [ ]  # Any other type of wheel don't need manylinux inputs
            ))
            (pypa.parseWheelFileName filename).platformTags
        )));
    });

})
