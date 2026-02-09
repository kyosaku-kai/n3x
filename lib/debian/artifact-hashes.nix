# ISAR Artifact Hashes - Mutable state mapping unique filenames to SHA256 hashes
#
# This is the ONLY file modified by the isar-build-all script.
# Each key is a unique artifact filename (from build-matrix.nix mkArtifactName),
# and each value is the base32-encoded SHA256 hash.
#
# To update: nix run '.#isar-build-all' -- --variant <id>
# To add manually: nix-hash --type sha256 --flat --base32 <artifact-path>
#
# Extracted from backends/debian/debian-artifacts.nix (commit baseline)
{
  # =========================================================================
  # qemuamd64 - base
  # =========================================================================
  "isar-base-qemuamd64.wic" = "0b5lk30580zn40d2nvl27hb47dgsl3scr1610pi19ima3q7lq76j";
  "isar-base-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-base-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - base-swupdate
  # =========================================================================
  "isar-base-swupdate-qemuamd64.wic" = "0iz7j1xp2zamsms4pwmh145n49z655b9jgb2536pkhqjznbnaqv7";
  "isar-base-swupdate-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-base-swupdate-qemuamd64-initrd.img" = "1hxwy6cx1k64mma0b6xldkvyy1xb3zdzj2m5x3kq0pv8c1ndza2g";

  # =========================================================================
  # qemuamd64 - agent
  # =========================================================================
  "isar-agent-qemuamd64.wic" = "044kk8vm07d6lpcn04xj20lqhzb1p5k677pyb5k8kzmbxaqxmh2x";
  "isar-agent-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-agent-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-simple-server-1
  # =========================================================================
  "isar-server-simple-server-1-qemuamd64.wic" = "0qbic16yzvr501qafmj2393cib6fzpavqrm36hk32k96mfd6gx4s";
  "isar-server-simple-server-1-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-simple-server-1-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-simple-server-2
  # =========================================================================
  "isar-server-simple-server-2-qemuamd64.wic" = "1as6l2p1s3wq8xl3n5kvyvc2ay8m0hq202ml55x54zpj5r2ppqf0";
  "isar-server-simple-server-2-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-simple-server-2-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-vlans-server-1
  # =========================================================================
  "isar-server-vlans-server-1-qemuamd64.wic" = "03aqjqdch7rkby3qpb0xf1clss57wvdycmp3w0kh84afpfh0hnj4";
  "isar-server-vlans-server-1-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-vlans-server-1-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-vlans-server-2
  # =========================================================================
  "isar-server-vlans-server-2-qemuamd64.wic" = "0pq78d398dzcdh8zpgvlp7bl8141nimmbc360zmvwvbigzrfqnb8";
  "isar-server-vlans-server-2-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-vlans-server-2-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-bonding-vlans-server-1
  # =========================================================================
  "isar-server-bonding-vlans-server-1-qemuamd64.wic" = "0gw5wya5mgw16pjxmrqlgi2y3b3kd4vdgy8zmv813n8sk5n02h7c";
  "isar-server-bonding-vlans-server-1-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-bonding-vlans-server-1-qemuamd64-initrd.img" = "13yc11v0cxjxgmgh9l89sfps6a045kyyidjw25cmallrlkyzfiwp";

  # =========================================================================
  # qemuamd64 - server-bonding-vlans-server-2
  # =========================================================================
  "isar-server-bonding-vlans-server-2-qemuamd64.wic" = "1s34528jsip3qlbzcrxsa262vwx3hvl7ifihqc5ab8jyhlbyr9dp";
  "isar-server-bonding-vlans-server-2-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-bonding-vlans-server-2-qemuamd64-initrd.img" = "13yc11v0cxjxgmgh9l89sfps6a045kyyidjw25cmallrlkyzfiwp";

  # =========================================================================
  # qemuamd64 - server-dhcp-simple-server-1
  # =========================================================================
  "isar-server-dhcp-simple-server-1-qemuamd64.wic" = "14d64qa1a1g3fpj380965v516v4xh41bzbrxakhfz60zly4a0cqf";
  "isar-server-dhcp-simple-server-1-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-dhcp-simple-server-1-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuamd64 - server-dhcp-simple-server-2
  # =========================================================================
  "isar-server-dhcp-simple-server-2-qemuamd64.wic" = "0q1avjrbk7aw44fdg4pby2ll5ff5n0x29lwlbfn35440prv78mdn";
  "isar-server-dhcp-simple-server-2-qemuamd64-vmlinuz" = "17nvnhvxr84r3210749ivlwa2qvgpjpjzj42kssy1bh02wzqrcg3";
  "isar-server-dhcp-simple-server-2-qemuamd64-initrd.img" = "0ca2sifbymwjq9an4nvfynqn36jymnd2izbgw1is89hxb5j3dcvi";

  # =========================================================================
  # qemuarm64 - base
  # =========================================================================
  "isar-base-qemuarm64.ext4" = "07wf98kmj73lmxlzbn18rab7bzzfn984dcfrslksxhnrrhcm7dxa";
  "isar-base-qemuarm64-vmlinux" = "1bkb7ndk2ylhc4xwcwi9s6cj66z15yllccsy8kayg3xw6pgk1y0j";
  "isar-base-qemuarm64-initrd.img" = "0xab92fayps5ckhpadjrd81kr8j3fah1dl8svcjgvcrcr3a6szmn";

  # =========================================================================
  # qemuarm64 - server
  # =========================================================================
  "isar-server-qemuarm64.ext4" = "08p32lyk942gkwrwd7fzpcfq0sagdrglg81bfbx0c6sjlqzaa6pz";
  "isar-server-qemuarm64-vmlinux" = "1bkb7ndk2ylhc4xwcwi9s6cj66z15yllccsy8kayg3xw6pgk1y0j";
  "isar-server-qemuarm64-initrd.img" = "0xab92fayps5ckhpadjrd81kr8j3fah1dl8svcjgvcrcr3a6szmn";

  # =========================================================================
  # jetson-orin-nano - base
  # =========================================================================
  "isar-base-jetson-orin-nano.tar.gz" = "1dj5ydl85rq15rcqv7xpmvyhp9q36325aw2cacl6n94crkgwb29y";

  # =========================================================================
  # jetson-orin-nano - server
  # =========================================================================
  "isar-server-jetson-orin-nano.tar.gz" = "117bbk3vr7vxanbi2dzr4hdibvvx9pa7jd74m4iwjw8iwr50k973";

  # =========================================================================
  # amd-v3c18i - agent
  # =========================================================================
  "isar-agent-amd-v3c18i.wic" = "018j6fm0sczhcpd1r1cfakbyxwb57y09j8br0dsr8lag55dd3j5n";
}
