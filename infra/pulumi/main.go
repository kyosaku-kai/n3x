// n3x AWS Infrastructure
//
// Provisions EC2 instances for NixOS GitLab runners with:
//   - x86_64 runner (c6i.2xlarge) for ISAR/Nix builds
//   - Graviton runner (c7g.2xlarge) for aarch64 builds
//   - EBS volumes: root (50GB), cache/ZFS (500GB), Yocto (100GB)
//   - Security group: SSH + HTTPS (Harmonia/Caddy) + all egress
//
// Deployment:
//   1. Build AMI: nix build '../nixos-runner#packages.x86_64-linux.ami-ec2-x86_64'
//   2. Register: ../nixos-runner/scripts/register-ami.sh --arch x86_64 ...
//   3. Configure: pulumi config set n3x:amiX86 ami-xxxx
//   4. Deploy: pulumi up
package main

import (
	"fmt"

	"github.com/pulumi/pulumi-aws/sdk/v6/go/aws/ebs"
	"github.com/pulumi/pulumi-aws/sdk/v6/go/aws/ec2"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// runnerSpec defines per-runner configuration for the createRunner helper.
type runnerSpec struct {
	name         string // Resource name prefix (e.g., "x86", "graviton")
	instanceType string // EC2 instance type
	amiId        string // Pre-registered NixOS AMI ID
}

// runnerOutputs holds the Pulumi outputs from creating a runner.
type runnerOutputs struct {
	instanceId pulumi.IDOutput
	publicIp   pulumi.StringOutput
	publicDns  pulumi.StringOutput
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "n3x")

		// --- Configuration ---

		rootVolumeSize := cfg.GetInt("rootVolumeSize")
		if rootVolumeSize == 0 {
			rootVolumeSize = 50
		}
		cacheVolumeSize := cfg.GetInt("cacheVolumeSize")
		if cacheVolumeSize == 0 {
			cacheVolumeSize = 500
		}
		yoctoVolumeSize := cfg.GetInt("yoctoVolumeSize")
		if yoctoVolumeSize == 0 {
			yoctoVolumeSize = 100
		}
		instanceTypeX86 := cfg.Get("instanceTypeX86")
		if instanceTypeX86 == "" {
			instanceTypeX86 = "c6i.2xlarge"
		}
		instanceTypeGraviton := cfg.Get("instanceTypeGraviton")
		if instanceTypeGraviton == "" {
			instanceTypeGraviton = "c7g.2xlarge"
		}

		// Custom NixOS AMI IDs (built via system.build.images.amazon, registered via register-ami.sh)
		amiX86 := cfg.Require("amiX86")
		amiArm64 := cfg.Get("amiArm64")

		// SSH public key for remote management.
		// Set via: pulumi config set n3x:sshPublicKey "ssh-ed25519 AAAA..."
		sshPublicKey := cfg.Require("sshPublicKey")

		// Optional: restrict SSH access to specific CIDR blocks.
		// Default: 0.0.0.0/0 (open — restrict in production).
		sshCidrBlocks := cfg.Get("sshCidrBlocks")
		if sshCidrBlocks == "" {
			sshCidrBlocks = "0.0.0.0/0"
		}

		// --- SSH Key Pair ---

		keyPair, err := ec2.NewKeyPair(ctx, "n3x-runner-key", &ec2.KeyPairArgs{
			KeyName:   pulumi.String("n3x-runner-key"),
			PublicKey: pulumi.String(sshPublicKey),
			Tags: pulumi.StringMap{
				"Project": pulumi.String("n3x"),
			},
		})
		if err != nil {
			return err
		}

		// --- Security Group ---

		sg, err := ec2.NewSecurityGroup(ctx, "n3x-runner-sg", &ec2.SecurityGroupArgs{
			Description: pulumi.String("Security group for n3x build runners"),
			Ingress: ec2.SecurityGroupIngressArray{
				// SSH access (restrict sshCidrBlocks in production)
				&ec2.SecurityGroupIngressArgs{
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(22),
					ToPort:      pulumi.Int(22),
					CidrBlocks:  pulumi.StringArray{pulumi.String(sshCidrBlocks)},
					Description: pulumi.String("SSH for management"),
				},
				// HTTPS for Harmonia binary cache (Caddy reverse proxy)
				&ec2.SecurityGroupIngressArgs{
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(443),
					ToPort:      pulumi.Int(443),
					CidrBlocks:  pulumi.StringArray{pulumi.String(sshCidrBlocks)},
					Description: pulumi.String("HTTPS for Harmonia/Caddy binary cache"),
				},
				// apt-cacher-ng proxy (cluster-internal)
				&ec2.SecurityGroupIngressArgs{
					Protocol:    pulumi.String("tcp"),
					FromPort:    pulumi.Int(3142),
					ToPort:      pulumi.Int(3142),
					CidrBlocks:  pulumi.StringArray{pulumi.String(sshCidrBlocks)},
					Description: pulumi.String("apt-cacher-ng proxy"),
				},
			},
			Egress: ec2.SecurityGroupEgressArray{
				// All outbound (GitLab, container registries, apt, etc.)
				&ec2.SecurityGroupEgressArgs{
					Protocol:    pulumi.String("-1"),
					FromPort:    pulumi.Int(0),
					ToPort:      pulumi.Int(0),
					CidrBlocks:  pulumi.StringArray{pulumi.String("0.0.0.0/0")},
					Description: pulumi.String("All outbound"),
				},
			},
			Tags: pulumi.StringMap{
				"Project": pulumi.String("n3x"),
				"Name":    pulumi.String("n3x-runner-sg"),
			},
		})
		if err != nil {
			return err
		}

		// --- Helper: Create Runner Instance + EBS Volumes ---

		createRunner := func(spec runnerSpec) (*runnerOutputs, error) {
			// EC2 instance with custom NixOS AMI (root volume from AMI)
			instance, err := ec2.NewInstance(ctx, fmt.Sprintf("n3x-runner-%s", spec.name), &ec2.InstanceArgs{
				Ami:          pulumi.String(spec.amiId),
				InstanceType: pulumi.String(spec.instanceType),
				KeyName:      keyPair.KeyName,
				VpcSecurityGroupIds: pulumi.StringArray{
					sg.ID(),
				},
				RootBlockDevice: &ec2.InstanceRootBlockDeviceArgs{
					VolumeSize:          pulumi.Int(rootVolumeSize),
					VolumeType:          pulumi.String("gp3"),
					DeleteOnTermination: pulumi.Bool(true),
					Tags: pulumi.StringMap{
						"Name":    pulumi.Sprintf("n3x-%s-root", spec.name),
						"Project": pulumi.String("n3x"),
					},
				},
				Tags: pulumi.StringMap{
					"Name":    pulumi.Sprintf("n3x-runner-%s", spec.name),
					"Project": pulumi.String("n3x"),
					"Role":    pulumi.String("gitlab-runner"),
					"NixOS":   pulumi.String("true"),
				},
			})
			if err != nil {
				return nil, fmt.Errorf("instance %s: %w", spec.name, err)
			}

			// Cache EBS volume (500GB gp3) — ZFS pool for /nix/store
			// Attached as /dev/sdf → appears as /dev/nvme1n1 on Nitro instances
			cacheVol, err := ebs.NewVolume(ctx, fmt.Sprintf("n3x-%s-cache", spec.name), &ebs.VolumeArgs{
				AvailabilityZone: instance.AvailabilityZone,
				Size:             pulumi.Int(cacheVolumeSize),
				Type:             pulumi.String("gp3"),
				// gp3 baseline: 3000 IOPS, 125 MB/s — sufficient for Nix store
				Tags: pulumi.StringMap{
					"Name":    pulumi.Sprintf("n3x-%s-cache", spec.name),
					"Project": pulumi.String("n3x"),
					"Purpose": pulumi.String("zfs-nix-store"),
				},
			})
			if err != nil {
				return nil, fmt.Errorf("cache volume %s: %w", spec.name, err)
			}

			_, err = ec2.NewVolumeAttachment(ctx, fmt.Sprintf("n3x-%s-cache-attach", spec.name), &ec2.VolumeAttachmentArgs{
				InstanceId: instance.ID(),
				VolumeId:   cacheVol.ID(),
				DeviceName: pulumi.String("/dev/sdf"),
			})
			if err != nil {
				return nil, fmt.Errorf("cache attach %s: %w", spec.name, err)
			}

			// Yocto EBS volume (100GB gp3) — DL_DIR/SSTATE_DIR (ephemeral)
			// Attached as /dev/sdg → appears as /dev/nvme2n1 on Nitro instances
			yoctoVol, err := ebs.NewVolume(ctx, fmt.Sprintf("n3x-%s-yocto", spec.name), &ebs.VolumeArgs{
				AvailabilityZone: instance.AvailabilityZone,
				Size:             pulumi.Int(yoctoVolumeSize),
				Type:             pulumi.String("gp3"),
				Tags: pulumi.StringMap{
					"Name":    pulumi.Sprintf("n3x-%s-yocto", spec.name),
					"Project": pulumi.String("n3x"),
					"Purpose": pulumi.String("yocto-cache"),
				},
			})
			if err != nil {
				return nil, fmt.Errorf("yocto volume %s: %w", spec.name, err)
			}

			_, err = ec2.NewVolumeAttachment(ctx, fmt.Sprintf("n3x-%s-yocto-attach", spec.name), &ec2.VolumeAttachmentArgs{
				InstanceId: instance.ID(),
				VolumeId:   yoctoVol.ID(),
				DeviceName: pulumi.String("/dev/sdg"),
			})
			if err != nil {
				return nil, fmt.Errorf("yocto attach %s: %w", spec.name, err)
			}

			return &runnerOutputs{
				instanceId: instance.ID(),
				publicIp:   instance.PublicIp,
				publicDns:  instance.PublicDns,
			}, nil
		}

		// --- x86_64 Runner ---

		x86, err := createRunner(runnerSpec{
			name:         "x86",
			instanceType: instanceTypeX86,
			amiId:        amiX86,
		})
		if err != nil {
			return err
		}

		// --- Graviton (aarch64) Runner ---
		// Only provisioned if amiArm64 is configured.

		var graviton *runnerOutputs
		if amiArm64 != "" {
			graviton, err = createRunner(runnerSpec{
				name:         "graviton",
				instanceType: instanceTypeGraviton,
				amiId:        amiArm64,
			})
			if err != nil {
				return err
			}
		}

		// --- Outputs ---

		ctx.Export("securityGroupId", sg.ID())
		ctx.Export("keyPairName", keyPair.KeyName)

		ctx.Export("x86InstanceId", x86.instanceId)
		ctx.Export("x86PublicIp", x86.publicIp)
		ctx.Export("x86PublicDns", x86.publicDns)
		ctx.Export("x86SshCommand", pulumi.Sprintf("ssh root@%s", x86.publicIp))

		if graviton != nil {
			ctx.Export("gravitonInstanceId", graviton.instanceId)
			ctx.Export("gravitonPublicIp", graviton.publicIp)
			ctx.Export("gravitonPublicDns", graviton.publicDns)
			ctx.Export("gravitonSshCommand", pulumi.Sprintf("ssh root@%s", graviton.publicIp))
		}

		return nil
	})
}
