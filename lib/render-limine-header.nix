# lib/render-limine-header.nix
#
# Pure function rendering the limine.conf HEADER lines (timeout/editor_enabled) that
# modules/system-manager-limine.nix owns an opinion about -- extracted out of that module so
# checks/system-manager.nix can test the rendering directly, without going through
# `lib.evalModules` or building anything: the header text is embedded inside a
# `pkgs.writeText`-built config file, one step removed from any option the module system exposes
# directly, so a pure function is the only way to prove this logic correct at eval time. Real
# keys, confirmed against nixpkgs' own installer
# (nixos/modules/system/boot/loader/limine/limine-install.py: `timeout: {timeout}` /
# `editor_enabled: {editor_enabled}`).
#
# `editor_enabled` is ALWAYS emitted, `timeout` only when set -- see
# modules/system-manager-limine.nix's own header comment on why an explicit editor stance is
# always rendered rather than left to limine's own upstream default.
{ lib }:
{ timeout, editor }:
lib.concatStringsSep "\n" (
  lib.optional (timeout != null) "timeout: ${toString timeout}"
  ++ [ "editor_enabled: ${if editor then "yes" else "no"}" ]
)
