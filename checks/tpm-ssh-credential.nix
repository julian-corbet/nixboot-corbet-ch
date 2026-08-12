{ pkgs, mkTpmSshCredential }:
let
  credentialName = "nixboot-test-initrd-hostkey";
  maintainer = mkTpmSshCredential {
    inherit pkgs credentialName;
    name = "test";
    espMountPoint = "/boot";
    pcrs = [ 7 ];
  };
in
pkgs.testers.nixosTest {
  name = "nixboot-tpm-ssh-credential";

  nodes.machine = {
    virtualisation.tpm.enable = true;
    environment.systemPackages = [
      maintainer
      pkgs.openssh
      pkgs.systemd
      pkgs.tpm2-tools
    ];
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e /dev/tpmrm0")
    machine.succeed("mkdir -p /boot")

    credential = "/boot/loader/credentials/${credentialName}.cred"
    public_key = "/boot/loader/credentials/${credentialName}.pub"
    command = "nixboot-seal-test-ssh-credential"

    with subtest("first successful boot creates only a sealed identity and its public key"):
        machine.succeed(command)
        machine.succeed(f"test -s {credential}")
        machine.succeed(f"test -s {public_key}")
        machine.succeed(
            "test $(find /boot/loader/credentials -maxdepth 1 -type f | wc -l) -eq 2"
        )
        machine.succeed(
            f"systemd-creds decrypt --tpm2-device=auto --name=${credentialName} "
            f"{credential} /run/nixboot-test-key"
        )
        machine.succeed("chmod 0600 /run/nixboot-test-key")
        machine.succeed(
            f"ssh-keygen -y -f /run/nixboot-test-key | cmp - {public_key}"
        )
        machine.succeed("shred -u /run/nixboot-test-key")

    with subtest("an unchanged PCR state preserves the exact identity"):
        machine.succeed(f"sha256sum {credential} {public_key} > /run/nixboot-before")
        machine.succeed(command)
        machine.succeed("sha256sum -c /run/nixboot-before")

    with subtest("a changed Secure Boot PCR invalidates the old credential"):
        machine.succeed(f"cp {public_key} /run/nixboot-old-public")
        machine.succeed(
            "tpm2_pcrextend 7:sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        machine.fail(
            f"systemd-creds decrypt --tpm2-device=auto --name=${credentialName} "
            f"{credential} /run/nixboot-stale-key"
        )
        machine.succeed("test ! -e /run/nixboot-stale-key")

    with subtest("one controlled reseal restores SSH identity availability"):
        machine.succeed(command)
        machine.fail(f"cmp -s /run/nixboot-old-public {public_key}")
        machine.succeed(
            f"systemd-creds decrypt --tpm2-device=auto --name=${credentialName} "
            f"{credential} /run/nixboot-new-key"
        )
        machine.succeed("chmod 0600 /run/nixboot-new-key")
        machine.succeed(
            f"ssh-keygen -y -f /run/nixboot-new-key | cmp - {public_key}"
        )
        machine.succeed("shred -u /run/nixboot-new-key")
        machine.succeed(
            "test $(find /boot/loader/credentials -maxdepth 1 -type f | wc -l) -eq 2"
        )
  '';
}
