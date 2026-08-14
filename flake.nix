{
  description = "Netskope Client for Linux, packaged as a NixOS module (x86_64)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # the Netskope client is proprietary
      };
    in
    {
      packages.${system} = {
        netskope-client = pkgs.callPackage ./pkgs/netskope-client.nix { };
        default = self.packages.${system}.netskope-client;
      };

      nixosModules.default = import ./modules/netskope.nix;

      formatter.${system} = pkgs.nixfmt-rfc-style;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.patchelf
          pkgs.file
          pkgs.binutils # readelf, for inspecting the payload
        ];
      };
    };
}
