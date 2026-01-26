# Machine Role Definitions for Unified K3s Platform
#
# This file defines standard machine naming and roles for K3s cluster tests.
# Both NixOS and ISAR backends should use these definitions to ensure
# consistency in test scripts and cluster configuration.
#
# TERMINOLOGY (Architecture Review 2026-01-26):
#   - Machine: Hardware platform (arch + BSP + boot method), e.g., qemu-amd64, n100-bare
#   - Role: Function in K3s cluster - "server" or "agent" only (K3s convention)
#   - System: Complete buildable artifact (nixosConfiguration / ISAR image)
#
# NAMING CONVENTION:
#   Test VMs: server-1, server-2, agent-1 (role-based, hostname format)
#             server_1, server_2, agent_1 (Python variable format)
#   Physical: n100-1, n100-2, n100-3 (hardware-based, in backends/nixos/hosts/)
#
# ROLES:
#   - server: K3s server (control plane) nodes
#   - agent: K3s agent (worker) nodes
#   - primary: First server node that initializes the cluster
#
# USAGE:
#   let
#     machineRoles = import ./machine-roles.nix { };
#   in {
#     # Get all servers
#     servers = machineRoles.byRole.server;  # [ "server-1" "server-2" ]
#
#     # Get primary node
#     primary = machineRoles.primary;  # "server-1"
#
#     # Check if a machine is a server
#     isServer = machineRoles.machines."server-1".role == "server";  # true
#   }

{}:

let
  # Standard machine definitions for K3s cluster testing
  # Supports various cluster topologies:
  #   - HA cluster: 2 servers + 1 agent (k3s-cluster-formation)
  #   - Network test: 1 server + 2 agents (k3s-network)
  #   - Full HA: 2 servers + 2 agents (future)
  # NOTE: These are TEST VM names. Physical hosts use n100-1/2/3 (in backends/nixos/hosts/)
  machines = {
    "server-1" = {
      role = "server";
      primary = true;
      pythonVar = "server_1";
      description = "K3s server (cluster init)";
    };
    "server-2" = {
      role = "server";
      primary = false;
      pythonVar = "server_2";
      description = "K3s server (joins cluster)";
    };
    "agent-1" = {
      role = "agent";
      primary = false;
      pythonVar = "agent_1";
      description = "K3s agent (worker 1)";
    };
    "agent-2" = {
      role = "agent";
      primary = false;
      pythonVar = "agent_2";
      description = "K3s agent (worker 2)";
    };
  };

  # Helper: Get machines by role
  byRole = {
    server = builtins.filter (name: machines.${name}.role == "server") (builtins.attrNames machines);
    agent = builtins.filter (name: machines.${name}.role == "agent") (builtins.attrNames machines);
  };

  # Helper: Get primary machine
  primary = builtins.head (builtins.filter (name: machines.${name}.primary) (builtins.attrNames machines));

  # Helper: All machine names
  allMachines = builtins.attrNames machines;

  # Helper: Convert hostname to Python variable name
  toPythonVar = hostname: machines.${hostname}.pythonVar;

  # Helper: Get machine info by name
  getMachine = hostname: machines.${hostname};

  # Python code snippet for standard machine iteration
  # Usage in testScript: ${machineRoles.pythonIterator}
  # NOTE: Tests may use subsets of these based on their topology
  pythonIterator = ''
    # Standard machine list for iteration (full HA topology)
    MACHINES = [
        (server_1, "server-1"),
        (server_2, "server-2"),
        (agent_1, "agent-1"),
        (agent_2, "agent-2"),
    ]
    SERVERS = [(server_1, "server-1"), (server_2, "server-2")]
    AGENTS = [(agent_1, "agent-1"), (agent_2, "agent-2")]
  '';

in
{
  inherit machines byRole primary allMachines;
  inherit toPythonVar getMachine pythonIterator;

  # Convenience exports
  serverCount = builtins.length byRole.server;
  agentCount = builtins.length byRole.agent;
  totalCount = builtins.length allMachines;
}
