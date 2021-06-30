{
  description = "Contain NixOS in a MicroVM";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-21.05";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
      flake-utils.lib.eachSystem systems (system: {
        
        packages = {
          qemu-example = self.lib.run "qemu" {
            inherit system;
            nixosConfig = {
              networking.hostName = "microvm";
              users.users.root.password = "";
            };
            # append = "boot.debugtrace";
          };

          qemu-example-service = self.lib.run "qemu" {
            inherit system;
            nixosConfig = {
              networking.hostName = "microvm-service";
              users.users.root.password = "";
            };
            volumes = [ {
              mountpoint = "/var";
              image = "var.img";
              size = 256;
            } ];
          };

          firecracker-example = self.lib.run "firecracker" {
            inherit system;
            nixosConfig = {
              networking.hostName = "microvm";
              users.users.root.password = "";
            };
            # interfaces = [ {
            #   id = "qemu";
            #   mac = "00:00:23:42:24:32";
            # } ];
            volumes = [ {
              mountpoint = "/var";
              image = "var.img";
              size = 256;
            } ];
          };

          cloud-hypervisor-example = self.lib.run "cloud-hypervisor" {
            inherit system;
            nixosConfig = {
              networking.hostName = "microvm";
              users.users.root.password = "";
            };
            # interfaces = [ {
            #   id = "qemu";
            #   mac = "00:00:23:42:24:32";
            # } ];
            volumes = [ {
              mountpoint = "/var";
              image = "var.img";
              size = 256;
            } ];
          };

          crosvm-example = self.lib.run "crosvm" {
            inherit system;
            nixosConfig = {
              networking.hostName = "microvm";
              networking.useDHCP = false;
              users.users.root.password = "";
            };
            volumes = [ {
              mountpoint = "/var";
              image = "var.img";
              size = 256;
            } ];
          };

        };

        checks =
            builtins.foldl' (result: hypervisor: result // {
              "microvm-${hypervisor}-test-startup-shutdown" =
                let
                  pkgs = nixpkgs.legacyPackages.${system};
                  runner = self.lib.run hypervisor {
                    inherit system;
                    nixosConfig = { pkgs, ... }: {
                      networking.hostName = "microvm-test";
                      networking.useDHCP = false;
                      systemd.services.poweroff-again = {
                        wantedBy = [ "multi-user.target" ];
                        serviceConfig.Type = "idle";
                        script =
                          let
                            exit = {
                              qemu = "reboot";
                              firecracker = "reboot";
                              cloud-hypervisor = "poweroff";
                              crosvm = "reboot";
                            }.${hypervisor};
                          in ''
                            ${pkgs.coreutils}/bin/uname > /var/OK
                            ${exit}
                          '';
                      };
                    };
                    volumes = [ {
                      mountpoint = "/var";
                      image = "var.img";
                      size = 32;
                    } ];
                  };
                in pkgs.runCommandNoCCLocal "microvm-${hypervisor}-test-startup-shutdown" {
                  buildInputs = [
                    runner
                    pkgs.libguestfs-with-appliance
                  ];
                } ''
                  ${runner.name} > $out

                  virt-cat -a var.img -m /dev/sda:/ /OK > $out
                  if [ "$(cat $out)" != "Linux" ] ; then
                    echo Output does not match
                    exit 1
                  fi
                '';
            }) {} (builtins.attrNames self.lib.hypervisors);

      }) // {
        lib = (
          import ./lib {
            nixpkgs-lib = nixpkgs.lib;
          }
        ) // {
          inherit (import ./lib/disk-image.nix {
            inherit self nixpkgs;
          }) mkDiskImage;

          hypervisors = builtins.mapAttrs (hypervisor: path: (
            import path {
              inherit self nixpkgs;
            }
          )) {
            qemu = ./lib/hypervisors/qemu.nix;
            firecracker = ./lib/hypervisors/firecracker.nix;
            cloud-hypervisor = ./lib/hypervisors/cloud-hypervisor.nix;
            crosvm = ./lib/hypervisors/crosvm.nix;
          };

          makeMicrovm =
            { hypervisor
            , system
            , nixosConfig
            , vcpu ? 1
            , mem ? 512
            , append ? ""
            , rootReserve ? "64M"
            , volumes ? []
            , ... }@args:
            let
              pkgs = nixpkgs.legacyPackages.${system};

              config = args // {
                inherit vcpu mem append rootReserve;
                inherit (config.nixos.config.networking) hostName;
                volumes = map ({ letter, ... }@volume: volume // {
                  device = "/dev/vd${letter}";
                }) (self.lib.withDriveLetters 1 volumes);

                rootDisk = self.lib.mkDiskImage {
                  inherit (config) system rootReserve nixos hostName;
                };

                nixos = nixpkgs.lib.nixosSystem {
                  inherit system;
                  extraArgs = {
                    inherit (config.rootDisk.passthru) writablePaths;
                    microvm = config;
                  };
                  modules = [
                    self.nixosModules.microvm
                    nixosConfig
                  ];
                };
              };

              extend = { command, preStart ? "", hostName, volumes, ... }@args: args // {
                run = pkgs.writeScriptBin "run-${hypervisor}-${hostName}" ''
                  #! ${pkgs.runtimeShell} -e

                  ${self.lib.createVolumesScript pkgs volumes}
                  ${preStart}

                  exec ${command}
                '';
              };
            in
              extend (
                self.lib.hypervisors.${hypervisor} config
              );

          run = hypervisor: args: (
            self.lib.makeMicrovm (args // {
              inherit hypervisor;
            })
          ).run;
        };

        nixosModules = {
          microvm = import ./nixos-modules/microvm.nix;
        };
      };
}
