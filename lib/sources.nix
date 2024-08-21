{ lib, ... }:

# Ordering (note that priorities marked with DEPRECATED are not supported)
#
let
  inherit (lib)
    filter
    length
    allUnique
    listToAttrs
    nameValuePair
    ;

  implicitPypi = {
    name = "pypi";
    url = "https://pypi.org/simple";
  };

in
{
  /*
    Parse pyproject.toml package sources

    As described in https://python-poetry.org/docs/repositories/#package-sources
  */
  mkSources =
    { project }:
    let
      source = project.pyproject.tool.poetry.source or [ ];

      primary = filter (s: s.priority == "primary") source;
      explicit = filter (s: s.priority == "explicit") source;
      supplemental = filter (s: s.priority == "supplemental") source;

      # Default sources in priority order
      defaultSources =
        # Source ordering copied from Poetry docs.
        # Those marked DEPRECATED are not supported.
        #
        # - default source (DEPRECATED),
        # - primary sources,
        primary
        # - implicit PyPI (unless disabled by another primary source, default source or configured explicitly),
        ++ lib.optional (length primary == 0) implicitPypi
        # - secondary sources (DEPRECATED),
        # - supplemental sources.
        ++ supplemental;

      # All sources
      allSources = defaultSources ++ explicit;
    in
    assert allUnique (map (s: s.name) allSources);
    {
      # Sources by name
      sources = listToAttrs (map (s: nameValuePair s.name s) allSources);
      # Priority order
      order = map (s: s.name) defaultSources;
    };
}
