{ lib }:
{
  optionPrefix,
  package,
  ignoredWhenPackageSet,
  extraAssertions ? [ ],
  extraWarnings ? [ ],
}:
let
  ignoredNonDefault =
    lib.filterAttrs (_name: spec: spec.value != spec.default) ignoredWhenPackageSet;

  ignoredWarnings = lib.mapAttrsToList
    (name: _spec:
      "${optionPrefix}.${name} is ignored when ${optionPrefix}.package is set.")
    ignoredNonDefault;
in
{
  warnings = (if package == null then [ ] else ignoredWarnings) ++ extraWarnings;
  assertions = extraAssertions;
}
