# Helper function to generate K3s token configuration with sops-nix
{ lib, pkgs, ... }:

{
  # Function to create K3s token configuration for servers and agents
  mkK3sTokenConfig =
    { role
    , # "server" or "agent"
      serverUrl ? null
    , # Required for agents and secondary servers
      tokenFile ? "/run/secrets/k3s-token"
    , clusterInit ? false
    , # Only true for first server
      nodeName ? null
    , nodeIp ? null
    , disableComponents ? [ "traefik" "servicelb" "local-storage" ]
    , flannelBackend ? "wireguard-native"
    , clusterCidr ? "10.42.0.0/16"
    , serviceCidr ? "10.43.0.0/16"
    , clusterDns ? "10.43.0.10"
    , extraFlags ? [ ]
    , labels ? { }
    , taints ? [ ]
    , ...
    }@args:
    let
      # Base K3s configuration
      baseConfig = {
        enable = true;
        inherit role tokenFile;
      } // lib.optionalAttrs (serverUrl != null) {
        serverAddr = serverUrl;
      } // lib.optionalAttrs (role == "server" && clusterInit) {
        clusterInit = true;
      };

      # Build extra flags list
      buildExtraFlags = [
        # Node identification
      ] ++ lib.optional (nodeName != null) "--node-name=${nodeName}"
      ++ lib.optional (nodeIp != null) "--node-ip=${nodeIp}"
      ++ lib.optionals (role == "server") ([
        "--cluster-cidr=${clusterCidr}"
        "--service-cidr=${serviceCidr}"
        "--cluster-dns=${clusterDns}"
        "--flannel-backend=${flannelBackend}"
      ] ++ map (component: "--disable=${component}") disableComponents)
      ++ extraFlags;

      # Generate node labels as flags
      labelFlags = lib.mapAttrsToList
        (key: value:
          "--node-label=${key}=${value}"
        )
        labels;

      # Generate node taints as flags
      taintFlags = map
        (taint:
          "--node-taint=${taint}"
        )
        taints;
    in
    {
      # K3s service configuration
      services.k3s = baseConfig // {
        extraFlags = lib.concatStringsSep " " (
          buildExtraFlags ++ labelFlags ++ taintFlags
        );
      };

      # Sops configuration for token management
      sops.secrets."k3s-token" = {
        sopsFile = ../secrets/k3s.yaml;
        format = "yaml";
        mode = "0400";
        owner = "root";
        path = tokenFile;
        restartUnits = [ "k3s.service" ];
      };

      # Ensure token file permissions
      systemd.services.k3s = {
        serviceConfig = {
          ExecStartPre = [
            "${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root $(dirname ${tokenFile})"
            "${pkgs.bash}/bin/bash -c 'until [ -f ${tokenFile} ]; do echo \"Waiting for K3s token...\"; sleep 2; done'"
          ];
        };
      };
    };

  # Function for primary server configuration
  mkK3sServerPrimary =
    { nodeName
    , nodeIp
    , advertiseAddress ? nodeIp
    , tlsSan ? [ ]
    , ...
    }@args:
    mkK3sTokenConfig
      {
        role = "server";
        clusterInit = true;
        inherit nodeName nodeIp;
        extraFlags = [
          "--advertise-address=${advertiseAddress}"
        ] ++ map (san: "--tls-san=${san}") ([ nodeIp advertiseAddress ] ++ tlsSan);
        labels = {
          "node-role.kubernetes.io/control-plane" = "true";
          "node-role.kubernetes.io/master" = "true";
        } // (args.labels or { });
      } // {
      # Additional primary server configuration
      systemd.services.k3s-post-start = {
        description = "K3s primary server post-start configuration";
        after = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = ''
            ${pkgs.bash}/bin/bash -c '
              # Wait for K3s to be ready
              until ${pkgs.k3s}/bin/k3s kubectl get nodes &>/dev/null; do
                echo "Waiting for K3s API to be ready..."
                sleep 5
              done

              # Export kubeconfig for other services
              ${pkgs.k3s}/bin/k3s kubectl config view --raw > /etc/rancher/k3s/k3s.yaml.export
              chmod 600 /etc/rancher/k3s/k3s.yaml.export

              echo "K3s primary server ready"
            '
          '';
        };
      };
    };

  # Function for secondary server configuration
  mkK3sServerSecondary =
    { nodeName
    , nodeIp
    , primaryServerUrl
    , advertiseAddress ? nodeIp
    , tlsSan ? [ ]
    , ...
    }@args:
    mkK3sTokenConfig {
      role = "server";
      serverUrl = primaryServerUrl;
      clusterInit = false;
      inherit nodeName nodeIp;
      extraFlags = [
        "--advertise-address=${advertiseAddress}"
      ] ++ map (san: "--tls-san=${san}") ([ nodeIp advertiseAddress ] ++ tlsSan);
      labels = {
        "node-role.kubernetes.io/control-plane" = "true";
        "node-role.kubernetes.io/master" = "true";
      } // (args.labels or { });
    };

  # Function for agent/worker configuration
  mkK3sAgent =
    { nodeName
    , nodeIp
    , serverUrl
    , labels ? { }
    , taints ? [ ]
    , dedicatedRole ? null
    , # e.g., "storage", "compute", "edge"
      ...
    }@args:
    let
      roleLabels = lib.optionalAttrs (dedicatedRole != null) {
        "node-role.kubernetes.io/${dedicatedRole}" = "true";
        "workload.n3x.io/type" = dedicatedRole;
      };

      roleTaints = lib.optional (dedicatedRole != null)
        "workload.n3x.io/${dedicatedRole}=true:NoSchedule";
    in
    mkK3sTokenConfig {
      role = "agent";
      inherit nodeName nodeIp serverUrl;
      labels = {
        "node-role.kubernetes.io/worker" = "true";
      } // roleLabels // labels;
      taints = taints ++ roleTaints;
    };

  # Function to generate kubeconfig for external access
  mkKubeconfig =
    { serverUrl
    , clusterName ? "n3x"
    , userName ? "admin"
    , namespace ? "default"
    , certificateAuthorityFile ? "/etc/rancher/k3s/server/tls/server-ca.crt"
    , clientCertificateFile ? "/etc/rancher/k3s/server/tls/client-admin.crt"
    , clientKeyFile ? "/etc/rancher/k3s/server/tls/client-admin.key"
    , ...
    }:
    ''
      apiVersion: v1
      kind: Config
      clusters:
      - cluster:
          certificate-authority: ${certificateAuthorityFile}
          server: ${serverUrl}
        name: ${clusterName}
      contexts:
      - context:
          cluster: ${clusterName}
          namespace: ${namespace}
          user: ${userName}
        name: ${clusterName}
      current-context: ${clusterName}
      users:
      - name: ${userName}
        user:
          client-certificate: ${clientCertificateFile}
          client-key: ${clientKeyFile}
    '';
}
