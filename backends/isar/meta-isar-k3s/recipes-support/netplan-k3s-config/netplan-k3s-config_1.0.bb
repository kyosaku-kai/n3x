# =============================================================================
# Netplan K3s Network Configuration
# =============================================================================
#
# PURPOSE:
#   Provides netplan network configuration for k3s clusters with support for
#   multiple network profiles matching the n3x project test infrastructure.
#
# NETWORK PROFILES:
#   - simple: Single flat network on eth1 (192.168.1.0/24)
#   - vlans: 802.1Q VLANs on eth1 trunk (cluster=VLAN200, storage=VLAN100)
#   - bonding-vlans: Bonded eth1+eth2 with VLANs on bond0
#
# CONFIGURATION:
#   Set these variables in your image recipe or local.conf:
#
#   NETPLAN_PROFILE - Network profile to use (simple|vlans|bonding-vlans)
#   NETPLAN_NODE_IP - Node IP for simple profile (e.g., 192.168.1.1)
#   NETPLAN_CLUSTER_IP - Cluster VLAN IP for vlan profiles (e.g., 192.168.200.1)
#   NETPLAN_STORAGE_IP - Storage VLAN IP for vlan profiles (e.g., 192.168.100.1)
#
# EXAMPLE (in image recipe or local.conf):
#   NETPLAN_PROFILE = "vlans"
#   NETPLAN_CLUSTER_IP = "192.168.200.1"
#   NETPLAN_STORAGE_IP = "192.168.100.1"
#
# =============================================================================

SUMMARY = "Netplan network configuration for k3s clusters"
DESCRIPTION = "Provides netplan YAML configuration for k3s network profiles"
HOMEPAGE = "https://github.com/timblaktu/isar-k3s"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b72c5df05c96dff79b35f2"

SRC_URI = "\
    file://simple.yaml \
    file://vlans.yaml \
    file://bonding-vlans.yaml \
"

inherit dpkg-raw

# Default to simple profile with placeholder IP
NETPLAN_PROFILE ?= "simple"
NETPLAN_NODE_IP ?= "192.168.1.1"
NETPLAN_CLUSTER_IP ?= "192.168.200.1"
NETPLAN_STORAGE_IP ?= "192.168.100.1"

# Runtime dependencies
# netplan.io is the Debian package that provides netplan
# For bonding, we also need ifenslave
DEBIAN_DEPENDS = "netplan.io"
DEBIAN_DEPENDS:append = "${@' ifenslave' if d.getVar('NETPLAN_PROFILE') == 'bonding-vlans' else ''}"

do_install() {
    install -d ${D}${sysconfdir}/netplan

    # Select and process the appropriate template
    profile="${NETPLAN_PROFILE}"
    case "$profile" in
        simple)
            sed -e "s|@NODE_IP@|${NETPLAN_NODE_IP}|g" \
                ${WORKDIR}/simple.yaml > ${D}${sysconfdir}/netplan/60-k3s-network.yaml
            ;;
        vlans)
            sed -e "s|@CLUSTER_IP@|${NETPLAN_CLUSTER_IP}|g" \
                -e "s|@STORAGE_IP@|${NETPLAN_STORAGE_IP}|g" \
                ${WORKDIR}/vlans.yaml > ${D}${sysconfdir}/netplan/60-k3s-network.yaml
            ;;
        bonding-vlans)
            sed -e "s|@CLUSTER_IP@|${NETPLAN_CLUSTER_IP}|g" \
                -e "s|@STORAGE_IP@|${NETPLAN_STORAGE_IP}|g" \
                ${WORKDIR}/bonding-vlans.yaml > ${D}${sysconfdir}/netplan/60-k3s-network.yaml
            ;;
        *)
            bbfatal "Unknown NETPLAN_PROFILE: $profile. Use simple, vlans, or bonding-vlans."
            ;;
    esac

    chmod 0600 ${D}${sysconfdir}/netplan/60-k3s-network.yaml
}

FILES:${PN} = "${sysconfdir}/netplan/60-k3s-network.yaml"
