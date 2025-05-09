{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem
      [
        "aarch64-darwin"
      ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          devShells = {
            default = pkgs.mkShellNoCC {

              buildInputs = [
                pkgs.gettext
                pkgs.autoconf
                pkgs.glibtool
                pkgs.automake
                pkgs.pkg-config
              ];

              shellHook = ''
                unset DEVELOPER_DIR
                unset SDKROOT

                export PATH=/usr/bin:$PATH
              '';
            };

          };
        }
      );
}
