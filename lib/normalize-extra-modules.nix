{ }:
args: modules:
builtins.map (entry:
  if builtins.isAttrs entry then
    entry
  else if builtins.isFunction entry then
    let
      result = entry args;
    in
    if builtins.isAttrs result then
      result
    else
      throw "extraModules function must return an attrset, got: ${builtins.typeOf result}"
  else if builtins.isPath entry || builtins.isString entry then
    entry
  else
    throw "extraModules entries must be attrsets, functions, or paths, got: ${builtins.typeOf entry}"
) modules
