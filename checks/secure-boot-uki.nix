{ pkgs
, mkUki
, mkUkiSigningRequest
, mkUkiSigner
, mkSignedUkiVerifier
}:
let
  signer = mkUkiSigner { inherit pkgs; };
  verifier = mkSignedUkiVerifier { inherit pkgs; };
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
in
pkgs.testers.nixosTest {
  name = "nixboot-secure-boot-uki";

  nodes.machine = {
    virtualisation.useBootLoader = true;
    virtualisation.useEFIBoot = true;
    virtualisation.useSecureBoot = true;
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.editor = false;
    boot.loader.efi.canTouchEfiVariables = true;
    environment.systemPackages = [ pkgs.sbctl signer verifier ];
  };

  testScript =
    { nodes, ... }:
    let
      toplevel = nodes.machine.system.build.toplevel;
      unsignedUki = mkUki {
        inherit pkgs toplevel;
        name = "nixboot-ovmf-nixrescue";
      };
      request = mkUkiSigningRequest {
        inherit pkgs unsignedUki;
        name = "generic-nixrescue";
        deviceClass = "nixnas";
        role = "nixrescue";
        version = "ovmf-integration";
      };
    in
    ''
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")
      machine.copy_from_host("${request}", "/tmp/nixboot-request")

      with subtest("sign the immutable request outside the Nix store"):
          machine.succeed("sbctl create-keys")
          machine.succeed(
              "nixboot-sign-uki /tmp/nixboot-request "
              "/var/lib/sbctl/keys/db/db.key /var/lib/sbctl/keys/db/db.pem /tmp/nixboot-signed"
          )
          machine.succeed(
              "nixboot-verify-signed-uki /tmp/nixboot-request /tmp/nixboot-signed "
              "/var/lib/sbctl/keys/db/db.pem"
          )

      with subtest("enroll only the disposable OVMF guest and select the signed UKI"):
          machine.succeed("sbctl enroll-keys --yes-this-might-brick-my-machine")
          esp = machine.succeed("bootctl --print-esp-path").strip()
          machine.succeed(f"sbctl sign {esp}/EFI/systemd/systemd-boot${efiArch}.efi")
          machine.succeed(f"sbctl sign {esp}/EFI/BOOT/BOOT${pkgs.lib.toUpper efiArch}.EFI")
          machine.succeed(
              f"install -Dm0644 /tmp/nixboot-signed/signed.efi {esp}/EFI/Linux/nixboot-test-rescue.efi"
          )
          machine.succeed("bootctl set-default nixboot-test-rescue.efi")

      machine.reboot()

      with subtest("firmware enforced Secure Boot and selected nixboot's signed UKI"):
          machine.wait_for_unit("multi-user.target")
          assert "Secure Boot: enabled (user)" in machine.succeed("bootctl status")
          assert "nixboot-test-rescue.efi" in machine.succeed("bootctl status")
          machine.succeed("grep -F 'init=${toplevel}/init' /proc/cmdline")
    '';
}
