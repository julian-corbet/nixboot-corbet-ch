# lib/register-boot-entry.nix
#
# The idempotent, self-healing `efibootmgr` registrar -- extracted out of
# modules/extra-entries.nix so every NixOS extra entry uses the exact same tested logic rather
# than a hand-copy drifting away from checks/default.nix. Pure `{ lib, pkgs }`, with no config
# reference, so a future backend can import it without duplicating this NVRAM safety mechanism.
#
# IDEMPOTENCY (the reason this exists as its own tool, not inlined per caller):
# `efibootmgr --create` is NOT idempotent -- a naive create-on-every-run piles up duplicate NVRAM
# entries until firmware boot-variable slots exhaust, a real and not-always-recoverable failure
# mode. This tool decides idempotency by matching BOTH the label AND the current device path
# against `efibootmgr -v`'s own output:
#   - label + path both match an existing entry -> true no-op, nothing written to NVRAM at all.
#   - label matches but the path differs -> the OLD entry is stale (the documented case:
#     `efibootmgr` encodes the partition's start LBA *and size* in the HD() device path, so
#     resizing the ESP invalidates every NVRAM entry pointing into it even with the partition GUID
#     unchanged) -- remove the stale entry(ies) first, THEN create the new one. Self-healing, not
#     merely idempotent: a second run after a legitimate path change converges to exactly one
#     correct entry instead of accumulating a second one beside a dead one.
#   - no matching label at all -> create.
{ lib, pkgs }:
let
  registerBootEntryText = ''
    set -euo pipefail

    esp=""
    label=""
    relpath=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --esp) esp="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --relpath) relpath="$2"; shift 2 ;;
        *) echo "nixboot-register-boot-entry: unknown argument '$1'" >&2; exit 1 ;;
      esac
    done
    if [ -z "$esp" ] || [ -z "$label" ] || [ -z "$relpath" ]; then
      echo "nixboot-register-boot-entry: --esp, --label and --relpath are all required" >&2
      exit 1
    fi

    # `efibootmgr -v` renders the loader path with BACKSLASHES regardless
    # of which separator was used to create the entry -- match against
    # that form, not the forward-slash form this tool is called with.
    # shellcheck disable=SC1003
    relpath_disp="$(printf '%s' "$relpath" | tr '/' '\\')"

    espdev="$(findmnt -no SOURCE "$esp")"
    diskdev="/dev/$(lsblk -no PKNAME "$espdev" | head -1)"
    partnum="$(lsblk -no PARTN "$espdev" | head -1)"
    [ -n "$diskdev" ] && [ -n "$partnum" ] || {
      echo "nixboot-register-boot-entry: could not resolve the disk/partition backing $esp (findmnt/lsblk gave disk='$diskdev' part='$partnum')" >&2
      exit 1
    }

    existing="$(efibootmgr -v 2>/dev/null || true)"

    if echo "$existing" | grep -F "$label" | grep -F "$relpath_disp" >/dev/null; then
      echo "nixboot-register-boot-entry: '$label' -> $relpath_disp already registered -- no-op"
      exit 0
    fi

    # Any entry with a MATCHING label but a DIFFERENT path is stale
    # (typically: the ESP was resized since it was created) -- remove it
    # before creating the correct one, so a re-run converges to exactly
    # one entry instead of accumulating a second one beside a dead one.
    stale_nums="$(echo "$existing" | grep -F "$label" | grep -oE '^Boot[0-9A-Fa-f]{4}' | sed 's/^Boot//' || true)"
    for num in $stale_nums; do
      echo "nixboot-register-boot-entry: removing stale entry Boot$num (label '$label' with an outdated path)"
      efibootmgr -b "$num" -B >/dev/null
    done

    efibootmgr --create --disk "$diskdev" --part "$partnum" --label "$label" --loader "$relpath" >/dev/null
    echo "nixboot-register-boot-entry: registered '$label' -> $relpath_disp"
  '';

  # `writeShellApplication` ALWAYS prepends its own `runtimeInputs` ahead of
  # whatever PATH the caller already had -- correct and load-bearing for the
  # real tool (a fixed, pinned toolset regardless of the caller's
  # environment), but it means a caller cannot shadow `efibootmgr` by simply
  # exporting a PATH with a stub directory first. `mkTestVariant` exists
  # SOLELY so checks/default.nix's idempotency proof can rebuild the exact
  # same script text with fake tool packages placed FIRST in the resulting
  # PATH instead -- nothing about production behavior depends on this.
  mkRegisterBootEntry = frontRuntimeInputs:
    pkgs.writeShellApplication {
      name = "nixboot-register-boot-entry";
      # gnused is NOT optional and NOT covered by coreutils: the stale-entry sweep above pipes
      # through `sed 's/^Boot//'`. A missing sed is a bare 127 at the exact moment this script is
      # deleting firmware entries, and the idempotency check cannot catch it -- a Nix build
      # sandbox's stdenv already has sed on PATH, so the test passes while a systemd unit with a
      # minimal PATH (which is what actually runs this in production) would not.
      runtimeInputs = frontRuntimeInputs ++ [ pkgs.efibootmgr pkgs.util-linux pkgs.gnugrep pkgs.gnused pkgs.coreutils ];
      text = registerBootEntryText;
    };

  registerBootEntry = (mkRegisterBootEntry [ ]).overrideAttrs (old: {
    passthru = (old.passthru or { }) // {
      mkTestVariant = frontRuntimeInputs: mkRegisterBootEntry frontRuntimeInputs;
    };
  });
in
{
  inherit registerBootEntryText mkRegisterBootEntry registerBootEntry;
}
