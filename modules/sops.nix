{ config, ... }:

{
  sops = {
    # Syncthing carries the encrypted file outside the public repository; it is read only at activation.
    defaultSopsFile = "${config.users.users.kosciak.home}/.config/secrets/${config.networking.hostName}.yaml";
    validateSopsFiles = false;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Mic92/sops-nix#974: on darwin the RSA host key is otherwise imported as a GPG key and fails activation.
    gnupg.sshKeyPaths = [ ];
  };
}
