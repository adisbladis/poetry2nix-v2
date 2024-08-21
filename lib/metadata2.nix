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
    hasPrefix
    isString
    match
    isList
    isAttrs
    toList
    elemAt
    filterAttrs
    all
    groupBy
    genericClosure
    attrNames
    any
    remove
    attrValues
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

  /*
    Resolve a Poetry project's dependencies.

    Returns an attribute set like:
    {
      requests = metadata2.parsePackage ...;
    }
  */
  resolveDependencies =
    # Top-level project
    { project }:
    let
      packages' = map self.parsePackage project.poetryLock.package;
    in
    # Environment parameters
    {
      # PEP-508 environment as returned by pyproject-nix.lib.pep508.mkEnviron
      environ,
      # Top-level project dependencies:
      # - as parsed by pyproject-nix.lib.pep621.parseDependencies
      # - as filtered by pyproject-nix.lib.pep621.filterDependencies
      dependencies,
    }:
    let
      # Get full Python version from environment for filtering
      pythonVersion = environ.python_full_version.value;

      # Project top-level dependencies
      #
      # Poetry contains it's Python dependency constraint in the regular dependency set,
      # but the interpreter isn't managed by Poetry, so filter it out.
      topLevelDependencies = filter (dep: dep.name != "python") dependencies.dependencies;

      # List parsed poetry.lock packages filtered by interpreter & environment
      packages =
        # Filter dependencies not compatible with this environment.
        map (self.filterPackage environ) (
          # Filter packages not compatible with this interpreter version
          filter (
            pkg: all (spec: pep440.comparators.${spec.op} pythonVersion spec.version) pkg.python-versions
          ) packages'
        );

      # Group list of package candidates by package name (pname)
      candidates = groupBy (pkg: pkg.name) packages;

      # Group list of package candidates by qualified package name (pname + version)
      allCandidates = groupBy (pkg: "${pkg.name}-${pkg.version}") packages;

      # Make key return for genericClosure
      mkKey = package: {
        key = "${package.name}-${package.version}";
        inherit package;
      };

      # Walk the graph from the top-level dependencies to get all possible dependency candidates
      allDependencies = groupBy (dep: dep.package.name) (genericClosure {
        # Build a startSet from filtered top-level dependency candidates
        startSet = concatMap (
          dep:
          map mkKey (
            filter (
              package: all (spec: pep440.comparators.${spec.op} package.version' spec.version) dep.conditions
            ) candidates.${dep.name}
          )
        ) topLevelDependencies;

        # Recurse into dependencies of dependencies
        operator =
          { key, package }:
          concatMap (
            dep:
            concatMap (
              name:
              let
                specs = map (constraint: constraint.version) dep.dependencies.${name};
              in
              map mkKey (
                filter (
                  package: any (all (spec: pep440.comparators.${spec.op} package.version' spec.version)) specs
                ) candidates.${name}
              )
            ) (attrNames dep.dependencies)
          ) allCandidates.${key};
      });

      depNames = attrNames allDependencies;

      # Reduce dependency candidates down to the one resolved dependency.
      reduceDependencies =
        attrs:
        let
          result = mapAttrs (
            name: candidates:
            if length candidates == 1 then
              (head candidates).package
            else
              let
                # Extract version constraints for this package from all other packages
                specs = concatMap (
                  n:
                  let
                    package = attrs.${n};
                  in
                  if isList package then
                    map (pkg: concatMap (c: c.version) (pkg.package.dependencies.${name} or [ ])) package
                  else if isAttrs package then
                    concatMap (c: c.version) (package.package.dependencies.${name} or [ ])
                  else
                    throw "Unhandled type: ${typeOf package}"
                ) (remove name depNames);
              in
              filter (
                package: any (all (spec: pep440.comparators.${spec.op} package.package.version' spec.version)) specs
              ) candidates
          ) attrs;
          done = all isAttrs (attrValues result);
        in
        if done then result else reduceDependencies result;

    in
    reduceDependencies allDependencies;

  /*
    Filter a parsed packages dependencies by it's PEP-508 environment.

    Filters out:
    - dependencies
    - extras

    Notably missing:
    - PEP-517 build-system
  */
  filterPackage =
    # PEP-508 environment as returned by pyproject-nix.lib.pep508.mkEnviron
    environ:
    let
      filterDeps = filter (dep: dep.markers == null || pep508.evalMarkers environ dep.markers);
    in
    # Parsed poetry.lock metadata2 package
    package:
    package
    // {
      # TODO: mapAttrs/filterAttrs combo is inefficient, we can do the equivalent manually
      dependencies = filterAttrs (_name: specs: length specs > 0) (
        mapAttrs (_name: filterDeps) package.dependencies
      );
      extras = mapAttrs (_: filterDeps) package.extras;
    };

  /*
    Fetch a parsed package.

    Invokes builtins.fetchGit for git and fetchPypiLegacy for PyPI.
  */
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
      builtins.fetchGit (
        {
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

  /*
    Partition a list of files from poetry.lock into categories:
    - sdists
    - wheels
    - eggs
    - others
  */
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

  /*
    Parse a package from poetry.lock.

    Note that the parsed version lives in `version'`, while the original verbatim string version is saved as `version`.
  */
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
          concatMap parseDependency dep
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

  /*
    Call buildPythonPackage with parameters from poetry.lock package.

    Note: Needs to be called with pre-filtered dependencies.
  */
  mkPackage =
    {
      # Pyproject.nix project (loadPoetryPyproject)
      project,
      # Parsed tool.poetry.source from pyproject.toml
      sources,
    }:
    # Package segment parsed by parsePackage
    {
      name,
      version, # deadnix: skip
      version', # deadnix: skip
      dependencies,
      description,
      optional,
      files,
      extras, # deadnix: skip
      python-versions, # deadnix: skip
      develop, # deadnix: skip
      source, # deadnix: skip
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
      # Whether to prefer prebuilt binary wheels over sdists
      preferWheel ? false, # TODO: Make globally configurable
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

    in
    buildPythonPackage (
      {
        pname = name;
        inherit version src format;

        dependencies = concatMap (
          name:
          let
            spec = dependencies.${name};
            dep = pythonPackages.${name};
            extras = spec.extras or [ ];
          in
          [ dep ] ++ map (extraName: dep.optional-dependencies.${extraName}) extras
        ) (attrNames dependencies);

        optional-dependencies = mapAttrs (_: extras: concatMap getExtra extras) extras;

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
              concatMap (
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
          );
      }
    );

})
