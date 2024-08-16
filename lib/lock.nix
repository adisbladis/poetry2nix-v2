{ lib, pyproject-nix, ... }:

let
  inherit (builtins) head nixVersion typeOf;
  inherit (lib)
    length
    filter
    listToAttrs
    nameValuePair
    optionalAttrs
    versionAtLeast
    mapAttrs
    concatMap
    mapAttrsToList
    concatLists
    hasPrefix
    isString
    match
    isList
    isAttrs
    toList
    elemAt
    filterAttrs
    ;

  inherit (pyproject-nix.lib) pep440 pep508;
  inherit (pyproject-nix.lib.poetry) parseVersionConds;
  inherit (pyproject-nix.lib.eggs) selectEggs parseEggFileName isEggFileName;
  inherit (pyproject-nix.lib.pypa)
    isWheelFileName
    isSdistFileName
    selectWheels
    parseWheelFileName
    ;

  # Select the best compatible wheel from a list of wheels
  selectWheels' =
    wheels: python:
    let
      # Filter wheels based on interpreter
      compatibleWheels = selectWheels python.stdenv.targetPlatform python (
        map (fileEntry: parseWheelFileName fileEntry.file) wheels
      );
    in
    map (wheel: wheel.filename) compatibleWheels;

  # Select the best compatible egg from a list of eggs
  selectEggs' =
    eggs': python:
    map (egg: egg.filename) (selectEggs python (map (egg: parseEggFileName egg.file) eggs'));

  optionalHead = list: if length list > 0 then head list else null;

in

lib.fix (self: {

  fetchPackage =
    {
      # The specific package segment from pdm.lock
      package,
      # Project root path used for local file/directory sources
      projectRoot,
      # Filename for which to invoke fetcher
      filename ? throw "Missing argument filename",
      # Parsed pyproject.toml contents # PyPI sources as extracted from pyproject.toml
      sources,
      fetchurl,
      fetchPypiLegacy,
    }:
    let
      file = package.files.all.${filename} or (throw "Filename '${filename}' not present in package");

      # Get list of URLs from sources
      urls = map (name: sources.sources.${name}.url) sources.order;

      sourceType = package.source.type or "";
      inherit (package) source;

    in
    if sourceType == "git" then
      (
        builtins.fetchGit {
          inherit (source) url;
          rev = source.resolved_reference;
        }
        // optionalAttrs (source ? reference) { ref = "refs/tags/${source.reference}"; }
        // optionalAttrs (versionAtLeast nixVersion "2.4") {
          allRefs = true;
          submodules = true;
        }
      )
    else if sourceType == "url" then
      (fetchurl {
        url =
          assert (baseNameOf source.url) == filename;
          source.url;
        inherit (file) hash;
      })
    else if sourceType == "file" then
      { outPath = projectRoot + "/${source.url}"; }
    else if sourceType == "legacy" then # Explicit source
      (fetchPypiLegacy {
        pname = package.name;
        inherit (file) file hash;
        inherit (sources.sources.${source.reference}) url;
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
      wheels = lib.lists.partition (f: isWheelFileName f.file) files;
      sdists = lib.lists.partition (f: isSdistFileName f.file) wheels.wrong;
      eggs = lib.lists.partition (f: isEggFileName f.file) sdists.wrong;
    in
    {
      # Group into precedence orders
      sdists = sdists.right;
      wheels = wheels.right;
      eggs = eggs.right;
      others = eggs.wrong;

      # Create an attrset of all files -> entry for easy hash lookup
      all = listToAttrs (map (f: nameValuePair f.file f) files);
    };

  # Parse a single package from poetry.lock
  parsePackage =
    let
      # Poetry extras are not in PEP-508 form:
      # cov = ["attrs[tests]", "coverage[toml] (>=5.3)"]
      #
      # Parse & normalize into format as returned by pep508.parseString
      parseExtra =
        let
          matchCond = builtins.match "(.+) \\((.+)\\)";
        in
        extra:
        let
          m = matchCond extra;
        in
        if m != null then
          pep508.parseString (elemAt m 0) // { conditions = parseVersionConds (elemAt m 1); }
        else
          pep508.parseString extra;

      # Poetry.lock contains a mixed style of dependency declarations:
      #
      # [package.dependencies]
      # colorama = {version = "*", markers = "sys_platform == \"win32\""}
      # pluggy = ">=1.5,<2"
      # arpeggio = [
      #     {version = "2.0.2", markers = "python_version >= \"3.7\" and python_version < \"3.10\""},
      #     {version = "2.0.1", markers = "python_version >= \"3.10\" and python_version < \"3.11\""},
      # ]
      #
      # Parse and normalize these types into list form.
      # colorama = [ { version = parseVersionConds dep.version; markers = pep508.parseMarkers dep.markers;  } ];
      parseDependency =
        dep:
        if isString dep then
          toList {
            version = parseVersionConds dep;
            markers = null;
          }
        else if isAttrs dep then
          toList {
            markers = if dep ? markers then pep508.parseMarkers dep.markers else null;
            version = if dep ? version then parseVersionConds dep.version else null;
          }
        else if isList dep then
          map parseDependency dep
        else
          throw "Unhandled dependency type: ${typeOf dep}";

    in
    {
      name,
      version,
      dependencies ? { },
      description ? "",
      optional ? false,
      files ? [ ],
      extras ? { },
      python-versions ? "*",
      source ? { },
      develop ? false,
    }:
    {
      inherit
        name
        version
        description
        optional
        source
        develop
        ;
      version' = pep440.parseVersion version;
      files = self.partitionFiles files;
      dependencies = mapAttrs (_: parseDependency) dependencies;
      extras = mapAttrs (_: extras: map parseExtra extras) extras;
      python-versions = parseVersionConds python-versions;
    };

  mkPackage =
    # Pyproject.nix project (loadPoetryPyproject)
    { project, sources }:
    # Package segment parsed by parsePackage
    {
      name,
      version,
      version', # deadnix: skip
      dependencies,
      description,
      optional,
      files,
      extras,
      source, # deadnix: skip
      python-versions, # deadnix: skip
      develop, # deadnix: skip
    }@package:
    {
      python,
      stdenv,
      buildPythonPackage,
      pythonPackages,
      wheelUnpackHook,
      pypaInstallHook,
      autoPatchelfHook,
      pythonManylinuxPackages,
      fetchurl,
      fetchPypiLegacy,
      __poetry2nix,
      # Whether to prefer prebuilt binary wheels over sdists
      preferWheel ? __poetry2nix.preferWheels,
    }:
    let
      # Select filename based on sdist/wheel preference order.
      filenames =
        let
          selectedWheels = selectWheels' files.wheels python;
          selectedSdists = map (file: file.file) files.sdists;
        in
        (if preferWheel then selectedWheels ++ selectedSdists else selectedSdists ++ selectedWheels)
        ++ selectEggs' files.eggs python
        ++ map (file: file.file) files.others;

      filename = optionalHead filenames;

      format =
        if filename == null || isSdistFileName filename then
          "pyproject"
        else if isWheelFileName filename then
          "wheel"
        else if isEggFileName filename then
          "egg"
        else
          throw "Could not infer format from filename '${filename}'";

      src = self.fetchPackage {
        inherit (project) projectRoot;
        inherit
          sources
          package
          filename
          fetchurl
          fetchPypiLegacy
          ;
      };

      # Get an extra + it's nested list of extras
      # Example: build[virtualenv] needs to pull in build, but also build.optional-dependencies.virtualenv
      getExtra =
        extra:
        let
          dep = pythonPackages.${extra.name};
        in
        [ dep ] ++ map (extraName: dep.optional-dependencies.${extraName}) extra.extras;

      # Filter dependencies by PEP-508 environment
      filterDeps = filter (
        dep: dep.markers == null || pep508.evalMarkers __poetry2nix.environ dep.markers
      );
      dependencies' = filterAttrs (_name: specs: length specs > 0) (
        mapAttrs (_name: filterDeps) dependencies
      );

    in
    buildPythonPackage (
      {
        pname = name;
        inherit version src format;

        dependencies = concatLists (
          mapAttrsToList (
            name: spec:
            let
              dep = pythonPackages.${name};
              extras = spec.extras or [ ];
            in
            [ dep ] ++ map (extraName: dep.optional-dependencies.${extraName}) extras
          ) dependencies'
        );

        optional-dependencies = mapAttrs (_: extras: concatMap getExtra (filterDeps extras)) extras;

        meta = {
          inherit description;
        };
      }
      // optionalAttrs (format == "wheel") {
        # Don't strip prebuilt wheels
        dontStrip = true;

        # Add wheel utils
        nativeBuildInputs = [
          wheelUnpackHook
          pypaInstallHook
        ] ++ lib.optional stdenv.isLinux autoPatchelfHook;

        buildInputs =
          # Add manylinux platform dependencies.
          lib.optionals (stdenv.isLinux && stdenv.hostPlatform.libc == "glibc") (
            lib.unique (
              concatLists (
                map (
                  tag:
                  (
                    if hasPrefix "manylinux1" tag then
                      pythonManylinuxPackages.manylinux1
                    else if hasPrefix "manylinux2010" tag then
                      pythonManylinuxPackages.manylinux2010
                    else if hasPrefix "manylinux2014" tag then
                      pythonManylinuxPackages.manylinux2014
                    else if hasPrefix "manylinux_" tag then
                      pythonManylinuxPackages.manylinux2014
                    else
                      [ ] # Any other type of wheel don't need manylinux inputs
                  )
                ) (parseWheelFileName filename).platformTags
              )
            )
          );
      }
    );

})
