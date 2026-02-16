# Internal CA/PKI module for n3x build runners
#
# Installs an internal root CA certificate into the system trust store
# and optionally configures NixOS ACME to use an internal CA (e.g., step-ca)
# instead of Let's Encrypt.
#
# The root CA certificate (public) can be committed to the repo.
# The root CA private key is kept OFFLINE — never in repo or agenix.
#
# CA hierarchy: Single root CA for prototype. To upgrade to root+intermediate:
#   1. Generate intermediate CA signed by root
#   2. Add intermediate cert to certificateFiles
#   3. Configure ACME to use intermediate CA endpoint
#   4. Root CA private key stays offline; intermediate handles issuance
#
# Certificate generation (offline):
#   # Using step CLI (smallstep):
#   step certificate create "n3x Root CA" root-ca.crt root-ca.key \
#     --profile root-ca --no-password --insecure
#
#   # Or using openssl:
#   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-384 \
#     -keyout root-ca.key -out root-ca.crt -days 3650 -nodes \
#     -subj "/CN=n3x Root CA/O=n3x"
#
#   Copy root-ca.crt to infra/nixos-runner/certs/n3x-root-ca.pem
#   Store root-ca.key in secure offline storage (NOT in repo)
{ config, lib, pkgs, ... }:

let
  cfg = config.n3x.internal-ca;
in
{
  options.n3x.internal-ca = {
    enable = lib.mkEnableOption "n3x internal CA trust configuration";

    rootCertFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the internal root CA certificate in PEM format.
        This is the public certificate, safe to commit to the repository.
        It will be added to the system trust store so that all TLS clients
        (curl, git, nix, etc.) trust certificates issued by this CA.
      '';
      example = lib.literalExpression "./certs/n3x-root-ca.pem";
    };

    extraCertFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Additional CA certificate files to trust (e.g., intermediate CAs).
        Each file should contain one PEM-encoded certificate.
      '';
    };

    acmeServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        ACME Directory Resource URI for an internal CA (e.g., step-ca).
        When set, NixOS ACME clients (used by Caddy, nginx, etc.) will
        request certificates from this endpoint instead of Let's Encrypt.
        When null, ACME is not configured by this module (use static certs
        or configure ACME separately).
      '';
      example = "https://ca.n3x.internal/acme/acme/directory";
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "infra@n3x.internal";
      description = ''
        Email address for ACME registration with internal CA.
        Only used when acmeServer is set.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "n3x.internal";
      description = ''
        Internal domain used for service hostnames.
        Used by other modules (e.g., caddy) to construct FQDNs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Install root CA (and any extras) into the system trust store.
    # This updates /etc/ssl/certs/ca-certificates.crt which is used by
    # curl, git, nix, and other OpenSSL/NSS consumers.
    security.pki.certificateFiles =
      [ cfg.rootCertFile ] ++ cfg.extraCertFiles;

    # Configure ACME defaults for internal CA (when acmeServer is set).
    # Services using security.acme (like Caddy) will automatically use
    # this endpoint for certificate issuance.
    security.acme = lib.mkIf (cfg.acmeServer != null) {
      acceptTerms = true;
      defaults = {
        server = cfg.acmeServer;
        email = cfg.acmeEmail;
      };
    };
  };
}
