  Full Flow: nix build → VM Test

  1. Nix Evaluation Phase

  nix build '.#checks.x86_64-linux.debian-cluster-dhcp-simple'
      ↓
  flake.nix calls mkISARClusterTest { networkProfile = "dhcp-simple"; }
      ↓
  mk-debian-cluster-test.nix:
    - Detects isDhcpProfile = true
    - Creates 3 machines:
      • dhcp_server (NixOS VM with dnsmasq)
      • server_1 (ISAR image from artifact registry)
      • server_2 (ISAR image from artifact registry)
    - Computes ISAR MACs: server_1→52:54:00:a9:d3:01, server_2→52:54:00:cc:9f:01
      ↓
  mk-debian-test.nix:
    - For NixOS (dhcp_server): mkNixOSVMScript → wraps NixOS VM run script
    - For ISAR (server_1/2): mkISARVMScript → custom QEMU launch script
    - Creates wrapped test driver with --start-scripts and --vlans

  2. Test Execution Phase

  Test derivation builds:
    nix sandbox runs nixos-test-driver
        ↓
  Test driver starts:
    1. Creates VDE switches for VLAN 1
    2. Sets QEMU_VDE_SOCKET_1=/build/tmp.../vde1.ctl
    3. Forks each VM by calling run-<name>-vm
        ↓
  run-server_1-vm (mk-debian-vm-script.nix):
    - Parses QEMU_VDE_SOCKET_* env vars
    - Computes MAC from "server_1" → 52:54:00:a9:d3:01
    - Launches QEMU with:
        -machine q35 -cpu host -enable-kvm
        -drive file=<.wic image>,if=virtio,snapshot=on
        -drive OVMF_CODE.fd, OVMF_VARS.fd (UEFI boot)
        -netdev vde,sock=.../vde1.ctl + MAC
        -serial null  ← FROM SCRIPT
        "$@"  ← ADDITIONAL ARGS FROM TEST DRIVER
        ↓
  Test driver appends to "$@":
    -chardev socket,id=shell,path=.../vm-state-server_1/shell
    -device virtio-serial
    -device virtconsole,chardev=shell
    -qmp unix:.../qmp
    -serial stdio  ← CREATES SECOND SERIAL PORT

  3. VM Boot Sequence (ISAR)

  QEMU starts → OVMF UEFI firmware
      ↓
  BdsDxe: "BdsDxe driver loaded"  ← WE SEE THIS
      ↓
  systemd-boot EFI application
      ↓
  Loads kernel + initrd from rootfs
  Kernel cmdline: "rootwait console=ttyS0,115200 net.ifnames=0 biosdevname=0 quiet loglevel=1"
      ↓
  Linux kernel boots (SILENT due to quiet loglevel=1)
      ↓
  systemd starts (SILENT due to ShowStatus=no from nixos-test-backdoor recipe)
      ↓
  nixos-test-backdoor.service should start:
    - ConditionPathExists=/dev/hvc0 ← MUST EXIST
    - After=dev-hvc0.device ← WAITS FOR DEVICE
    - ExecStart=/usr/lib/nixos-test/backdoor.sh
        ↓
  backdoor.sh:
    1. Waits for /dev/ttyS0 to exist
    2. exec 3>/dev/ttyS0 (debug output to serial)
    3. exec < /dev/hvc0 > /dev/hvc0  ← REDIRECTS STDIN/OUT TO virtio-console
    4. echo "Spawning backdoor root shell..."  ← MAGIC STRING
    5. exec bash --norc

  4. Test Driver Connection

  Test driver waits for shell socket connection:
    - Polls socket at .../vm-state-server_1/shell
    - Waits for "Spawning backdoor root shell..." string
    - Once received, Machine object is ready for .succeed()/.execute() calls

  ---
  Critical Points Where Things Could Break

  | Location                      | What Happens                   | Failure Mode                       |
  |-------------------------------|--------------------------------|------------------------------------|
  | ConditionPathExists=/dev/hvc0 | systemd checks for device      | Service SKIPPED if missing         |
  | After=dev-hvc0.device         | systemd waits for udev         | Service DELAYED until device ready |
  | exec < /dev/hvc0 > /dev/hvc0  | Script redirects I/O           | FAILS SILENTLY if device gone/bad  |
  | virtio_console module         | Kernel must load module        | No /dev/hvc0 created               |
  | getty masking                 | Recipe masks serial-getty@hvc0 | Conflict if not masked             |

  ---
  Key Observations

  NixOS dhcp_server VM works because:
  - Uses direct kernel boot (-kernel, -initrd, -append)
  - NixOS test infrastructure has built-in backdoor.service
  - NixOS kernels always have virtio modules loaded

  ISAR VMs don't work because:
  - Uses UEFI boot through disk image
  - Relies on our custom nixos-test-backdoor package
  - Debian kernel module loading is separate from boot

  ---
  My Hypothesis

  Looking at the kernel cmdline difference:

  Previous (GRUB-based, which worked for simple/vlans/bonding tests):
  rootwait rootwait console=ttyS0,115200 console=tty0

  Current (systemd-boot):
  rootwait console=ttyS0,115200 net.ifnames=0 biosdevname=0 quiet loglevel=1

  The quiet loglevel=1 suppresses kernel messages. This is good because it keeps hvc0 clean.

  BUT - did you change the systemd-boot WKS file or kernel cmdline BETWEEN when simple/vlans/bonding tests worked and now?

  The more likely issue is: The ISAR images in nix store might not have the nixos-test-backdoor package installed at all, or the package was
   rebuilt incorrectly.

  Can you confirm:
  1. Were simple/vlans/bonding-vlans ISAR tests passing recently?
  2. Were those tests using GRUB or systemd-boot images?
  3. Did you rebuild the dhcp-simple images fresh, or copy/modify existing ones?

