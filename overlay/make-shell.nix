let
  defaultResolver = { source, name, version, ...}:
    throw "do not know how to resolve ${name} ${version} ${source}";
  crates-io-index = "registry+https://github.com/rust-lang/crates.io-index";

  default-registry-maps = {
    ${crates-io-index} = "crates-io";
  };
in
{
  packageFun ? _: throw "missing package function",
  packageResolver ? defaultResolver,
  excludeCrates ? {},
  registryMapping ? default-registry-maps,
  environment ? {},
  features ? {},

  lib,
  stdenv,
  callPackage,
  pkgs,
  mkCrate,
  mkLocalRegistry,
  mkShell,
  rustLib,
  fetchgit,
  cargo,
  rustc,
}:
with lib;
let
  config = {
    resolver = { source, name, version, sha256, source-info }@args:
      {
        inherit source name version;
      } //
      (if source == crates-io-index then
        {
          tarball = rustLib.fetchCratesIo { inherit name version sha256; };
          kind = "registry";
        }
      else if rustLib.isGit source then
        {
          src = fetchgit {
            inherit sha256;
            inherit (source-info) rev url;
          };
          kind = "git";
        }
      else
        packageResolver args);
  };
  mkCrate' = { src, package-id, dependencies, cargo-manifest, ... }:
    {
      inherit src;
      manifest = cargo-manifest;
      deps =
        listToAttrs
          (flatten
            (map
              (dep:
                map
                (name: { inherit name; value = true; })
                dep.toml-names)
              dependencies));
    };

  rpkgs =
    lib.fix
      (packageFun {
        inherit pkgs stdenv callPackage rustLib config;
        mkRustCrate = mkCrate';
      });

  filterPackages = filter: pkgs:
    let
      included-keys = lib.filter (key: filter ? ${key} -> filter.${key} != null) (attrNames pkgs);
    in
    if filter == "*" then
      {}
    else
      listToAttrs
        (map
          (key:
            {
              name = key;
              value =
                if filter ? ${key} then
                  filterPackages filter.${key} pkgs.${key}
                else
                  pkgs.${key};
            })
          included-keys);

  fpkgs = filterPackages excludeCrates rpkgs;

  regMaps = default-registry-maps // registryMapping;

  registries =
    let
      makeRegistry = reg: crates:
        let
          name = regMaps.${reg};
          crates' =
            mapAttrsToList
              (name: versions:
                mapAttrsToList
                  (version: crate:
                    let
                      inherit (crate.src) name version source;
                      activated-features = features.${source}.${name}.${version} or null;
                    in
                    if crate.src.kind or "unknown" == "registry" && crate.src ? tarball then
                      mkCrate {
                        inherit (crate.src) name version tarball;
                        inherit (crate) manifest deps;
                        features = if activated-features == null then null else activated-features;
                      }
                    else if crate.src.kind or "unknown" == "registry" && crate.src ? src then
                      mkCrate {
                        inherit (crate.src) name version src;
                        inherit (crate) manifest deps;
                        features = if activated-features == null then null else activated-features;
                      }
                    else
                      [])
                versions
              )
              crates;
        in
        {
          inherit name;
          index = reg;
          local-registry = mkLocalRegistry {
            inherit name;
            crates = flatten crates';
          };
        };
    in
    mapAttrsToList makeRegistry (filterAttrs (reg: _: regMaps ? ${reg}) fpkgs);

  replacementManifest =
    concatStringsSep
      "\n"
      (map
        ({ name, index, local-registry }:
        ''
          [registries.'${name}']
          index = "${index}"
          [source.'${name}']
          registry = "${index}"
          replace-with = "vendored-${name}"
          [source.'vendored-${name}']
          local-registry = "${local-registry}"
        '')
        registries);
in
pkgs.mkShell (environment // {
  nativeBuildInputs = [ cargo rustc ];

  inherit replacementManifest;
  passAsFile = [ "replacementManifest" ];
  shellHook = ''
    vendor_source() {
      mkdir -p .cargo
      touch .cargo/config
      cat $replacementManifestPath >>.cargo/config
    }
  '';
})
