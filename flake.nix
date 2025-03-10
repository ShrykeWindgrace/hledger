{
  description = "Hledger flake";
  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixpkgs-unstable";
    };
  };
  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      ghc = "ghc966";
      pkgs = nixpkgs.legacyPackages.${system};

      packageNames = [ "hledger" ];
      haskellPackages_1 =
        pkgs.haskell.packages.${ghc}.extend (hself: hsuper: {
          base-compat = hsuper.base-compat_0_14_1;
          base-compat-batteries = hsuper.base-compat-batteries_0_14_1;
          aeson = hsuper.aeson_2_2_3_0;
          time-compat = hsuper.time-compat_1_9_7;
          tasty = hsuper.tasty_1_5_2;
          hashable = hsuper.hashable_1_5_0_0;
        });
      haskellPackages =
        haskellPackages_1.extend (hself: hsuper: {
          hledger-lib = hself.callCabal2nix "hledger-lib" "${self}/hledger-lib" { };
          hledger = hself.callCabal2nix "hledger" "${self}/hledger" { };
        });
      packagePostOverrides = pkg: with pkgs.haskell.lib.compose; pkgs.lib.pipe pkg [
        disableExecutableProfiling
        disableLibraryProfiling
        dontBenchmark
        dontCoverage
        dontDistribute
        dontHaddock
        dontHyperlinkSource
        doStrip
        enableDeadCodeElimination
        justStaticExecutables

        dontCheck
      ];
      makePackages = pkgs:
        pkgs.lib.mapAttrs
          (_name: packagePostOverrides) # we can't apply overrides inside our overlay because it will remove linking info
          #(pkgs.lib.getAttrs packageNames (haskellPackages pkgs))
          (pkgs.lib.getAttrs packageNames haskellPackages )
      ;
      packagesDynamic = makePackages pkgs;
    in
    {
      packages.${system} = {
        hledger = packagesDynamic.hledger;
        default = self.packages.${system}.hledger;
    };
      #packages.${system} = {
      #hledger = haskellPackages.hledger;
      #};
      devShells.${system}.default = haskellPackages.shellFor {
        packages = p: [
          p.hledger
        ];
        nativeBuildInputs = [
          #haskellPackages.stan
          #haskellPackages.cabal-install
          #haskellPackages.weeder
          #haskellPackages.stylish-haskell
        ];
      };
    };

}
