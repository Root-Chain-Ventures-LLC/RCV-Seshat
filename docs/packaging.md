# Packages (.deb and .rpm)

Seshat ships three Linux packages, each as `.deb` and `.rpm` for `amd64` (`x86_64`) and `arm64`
(`aarch64`). They hold static binaries (the web UI embedded) and depend on nothing but systemd and the
usual base system. Every release attaches them, together with binary tarballs, an install bundle and
`SHA256SUMS`. Containers and Kubernetes are covered by the README and
[`kubernetes.md`](kubernetes.md). A ready-to-run virtual machine image (qcow2 and OVA) is described under
"Virtual appliance" below.

| Package | What it runs | Unit | Configuration | State |
|---|---|---|---|---|
| `seshat` | the gateway and console (`/usr/bin/seshat`) | `seshat.service` | `/etc/seshat/seshat.env` | `/var/lib/seshat` |
| `seshat-device-tracker` | the Device Tracker SSO portal (`/usr/bin/device-tracker`, [`device-tracker-portal.md`](device-tracker-portal.md)) | `seshat-device-tracker.service` | `/etc/seshat/device-tracker.env` | `/var/lib/seshat-device-tracker` |
| `seshat-edge` | an edge collector (`/usr/bin/seshat-edge`, the same binary started with `--role edge`, [`edge.md`](edge.md)) | `seshat-edge.service` | `/etc/seshat/edge.env` | `/var/lib/seshat-edge` |

The three can be installed side by side.

## What is in each package

`seshat`:

| Path | |
|---|---|
| `/usr/bin/seshat` | the binary |
| `/usr/lib/systemd/system/seshat.service` | the unit ([`deploy/systemd/seshat.service`](../deploy/systemd/seshat.service)) |
| `/etc/seshat/seshat.env` | your settings; a configuration file (see upgrades below), mode 0600 |
| `/usr/share/seshat/packs/` | the built-in vendor packs (`SESHAT_PACKS_DIR`) |
| `/usr/share/seshat/systemd/drop-ins/` | optional capability drop-ins (see below) |
| `/usr/share/doc/seshat/` | `LICENSE` and a pristine `seshat.env.example` |

`seshat-device-tracker` has the binary, its unit, `/etc/seshat/device-tracker.env` and its doc directory.
`seshat-edge` has the binary as `/usr/bin/seshat-edge`, its unit, `/etc/seshat/edge.env`, its own copy of the
packs under `/usr/share/seshat-edge/packs` (a fallback until the server's packs arrive), the relay drop-in and
its doc directory.

The install scripts:

* create a system user and group per service: `seshat` for the gateway and **`seshat-tracker` for the portal**
  (different users on purpose: the portal faces users outside the collectors' network, so it must not run as
  the user that owns the gateway's database and key; the edge unit uses a transient user, `DynamicUser`);
* create each service's own key file when it does not hold one yet: `/etc/seshat/secret.env` for the gateway
  and `/etc/seshat/device-tracker-secret.env` for the portal, each a random `SESHAT_SECRET_KEY`, mode 0600,
  readable by root only (systemd hands the value to the process; the service user cannot open the file). They
  are not package files: no upgrade, removal or purge touches them. A `SESHAT_SECRET_KEY` in `seshat.env`
  overrides the generated one, `SESHAT_SECRET_KEY_FILE` overrides both (every node of a cluster needs the same
  key; see [`storage.md`](storage.md)). **Upgrading the portal** from a version that shared `secret.env` copies
  that key into the portal's own file once, so data the portal sealed stays readable, and hands the portal's
  state directory to `seshat-tracker`;
* create the state directories mode 0700 owned by the service user, and take "other" access away from an
  environment file that an administrator left readable by everyone;
* run `systemctl daemon-reload`. A first install does **not** enable or start anything; an upgrade restarts
  a unit that was running.

## Install

```sh
# Debian 12+, Ubuntu 22.04+
apt install ./seshat_<version>-1_amd64.deb
# RHEL / Rocky / Alma 9+, Fedora
dnf install ./seshat-<version>-1.x86_64.rpm

sha256sum -c --ignore-missing SHA256SUMS      # in the directory with the downloaded files
```

Then review `/etc/seshat/seshat.env` and start it:

```sh
systemctl enable --now seshat
curl -s http://127.0.0.1:8080/api/health        # {"ok":true}
seshat --version                                 # seshat X.Y.Z (commit ..., built ...)
```

The first start logs a one-time **setup token** (`journalctl -u seshat | grep setup_token`) that the setup
wizard asks for before it creates the administrator; open `http://<host>:8080` from a trusted network (or
set `SESHAT_LISTEN=127.0.0.1:8080` and put a TLS proxy in front first, [`hardening.md`](hardening.md)). The unit listens on the standard ports:
UI and API on 8080, SNMP traps on 162/udp, syslog on 514/udp and tcp; flows (2055, 4739, 6343/udp) and the
telemetry dial-out listener as documented in `.env.example`. Any of these can be changed in `seshat.env`.

## Configuration and data

| | Path | Notes |
|---|---|---|
| Settings | `/etc/seshat/seshat.env`, `device-tracker.env`, `edge.env` | `KEY=value` lines, the same variables as `.env.example`; read by systemd (as root) before the process starts, so they can stay 0600. Restart the unit after a change. |
| Defaults | the unit's `Environment=` lines | data and packs directories, listen addresses; a line in the env file wins |
| Secret key | `/etc/seshat/secret.env` (portal: `/etc/seshat/device-tracker-secret.env`) | generated once, root-only 0600; **back it up separately from the data** ([`hardening.md`](hardening.md)) |
| Data | `/var/lib/seshat` | SQLite database (unless `SESHAT_DATABASE_URL` points at PostgreSQL), destination queues, MIB uploads (`mibs/`). Owned by `seshat`, mode 0700 (files 0600: the units run with `UMask=0077`). Back it up. |
| Packs | `/usr/share/seshat/packs` | replaced by every upgrade; MIB uploads live in the data directory |
| Logs | the journal | `journalctl -u seshat` |

The units are sandboxed beyond `ProtectSystem=strict` (system-call filter, no new privileges, restricted
address families and namespaces, hidden `/proc` of other users, private `/tmp` and devices; `systemd-analyze
security` rates `seshat.service` 1.5 and `seshat-device-tracker.service` 1.3, the same binary as the edge runs
at 1.6). The whole file system is read-only for the process except its state directory. Certificates and keys you reference (for example `SESHAT_SYSLOG_TLS_CERT`) must be readable
by the `seshat` user; put them under `/etc/seshat/tls/` with group `seshat` and mode 0640.

A path the service must **write** outside its state directory, typically a `SESHAT_OUTPUT_DIR` for file
destinations somewhere else, needs a drop-in; without it the destination reports `read-only file system`
and its events stay queued (nothing is lost):

```ini
# /etc/systemd/system/seshat.service.d/output-dir.conf
[Service]
ReadWritePaths=-/srv/seshat-output
```

The directory must exist and be writable by the `seshat` user (`install -d -o seshat -g seshat -m 0700
/srv/seshat-output`). The leading `-` makes a missing directory a no-op instead of failing the unit with
status 226/NAMESPACE; drop it if you would rather have the unit refuse to start. Then
`systemctl daemon-reload && systemctl restart seshat`.

Do not run these units as root (`User=root` in a drop-in): the system-call filter excludes the privileged
calls, including `fchown`, which SQLite makes when it creates the database as root, so the process would be
killed at its first start. The packages ship dedicated users (`seshat`, `seshat-tracker`) for that reason.

The portal in mode `shared` with SQLite would need the gateway's data directory, which the portal's own user
cannot (and should not) open: on one host use PostgreSQL for mode `shared`.

## Capabilities

By default `seshat` runs as the unprivileged user `seshat` with one capability, `CAP_NET_BIND_SERVICE`
(ports 162 and 514). Some features need more; each has a drop-in under `/usr/share/seshat/systemd/drop-ins/`
that adds exactly that, on top of the unit's own settings:

| Feature | Needs | Drop-in |
|---|---|---|
| Standalone, external load balancer (HA mode 4), edges | nothing more | none |
| VRRP, HA modes 1 and 2 ([`ha.md`](ha.md)) | `CAP_NET_ADMIN`, `CAP_NET_RAW`, `AF_PACKET` | `vrrp.conf` |
| Anycast with BGP, HA mode 3 | `CAP_NET_ADMIN` (addresses on the loopback, TCP-MD5) | `anycast-bgp.conf` |
| Raw relay with `preserve_source` ([`outputs.md`](outputs.md)) | `CAP_NET_RAW` | `nms-relay-preserve-source.conf` (also for `seshat-edge`) |

Install one by copying it into the unit's drop-in directory:

```sh
install -D -m 0644 /usr/share/seshat/systemd/drop-ins/vrrp.conf /etc/systemd/system/seshat.service.d/vrrp.conf
systemctl daemon-reload && systemctl restart seshat
systemctl show seshat -p AmbientCapabilities     # now lists cap_net_admin cap_net_raw
```

Without a capability the feature reports exactly what is missing (Cluster page, destination state) and
everything else keeps running. The Device Tracker portal needs no capabilities at all.

## Upgrade

Take a backup first, upgrade the server before the edges ([`hardening.md`](hardening.md)). Install the newer package the same way (`apt install ./...deb`, `dnf install ./...rpm` or `dnf upgrade`).
Your env files are kept: when the shipped example changed, apt asks or leaves it as `seshat.env.dpkg-dist`,
rpm writes `seshat.env.rpmnew`. A running unit is restarted; migrations run on start (once per cluster).

## Uninstall

```sh
apt remove seshat        # keeps /etc/seshat/seshat.env
apt purge seshat         # also deletes /etc/seshat/seshat.env
dnf remove seshat        # a changed seshat.env is kept as seshat.env.rpmsave
```

Removal stops and disables the unit. **No removal or purge ever deletes `/var/lib/seshat`,
`/etc/seshat/secret.env` or the `seshat` user**: the data and the key that seals the stored credentials are
too valuable to lose to a mistyped command, and a reinstall picks them up again. To remove everything, after
the package is gone:

```sh
rm -rf /var/lib/seshat /var/lib/seshat-device-tracker /var/lib/private/seshat-edge /etc/seshat
userdel seshat
```


| Release asset | Contents |
|---|---|
| `seshat_<v>_linux_<arch>.tar.gz` | `seshat`, `device-tracker`, `packs/`, `LICENSE` |
| `seshat-appliance_<v>_amd64.qcow2`, `.ova` | the virtual appliance (below) |
| `install-bundle.tar.gz` | the compose files, `.env.example`, the systemd units and drop-ins, the env examples |
| `SHA256SUMS` | checksums of every asset |
| `SHA256SUMS.sig`, `cosign.pub` | the signature over `SHA256SUMS` and the public key to check it with (when the release was signed) |
| `*.spdx.json` | SPDX software bills of materials: the source tree and both images |

Verifying the signature: [`hardening.md`](hardening.md), "Verifying a release".

## Virtual appliance

Every release also carries a ready-to-run virtual machine: Debian 13 ("trixie") with the `seshat` package of the
same release installed and started. It listens on its own ports and on SSH (keys only), nothing else ([Ports](#ports)). Use it when you would rather import a VM than install
a package on a server you maintain.

| File | For |
|---|---|
| `seshat-appliance_<version>_amd64.qcow2` | KVM and libvirt, Proxmox VE, OpenStack and anything else that reads qcow2 |
| `seshat-appliance_<version>_amd64.ova` | VMware ESXi, Workstation and Fusion, VirtualBox, and Proxmox VE (`qm importovf`) |

Both hold the same disk (8 GiB virtual size, about 270 MB to download; the system uses about 0.5 GiB of it until your
data grows) and boot with BIOS or UEFI firmware, with **Secure Boot off**: the boot loader is an unsigned GRUB (no
shim), so a firmware that enforces Secure Boot refuses it. They are listed in `SHA256SUMS` like every other asset: verify the
signature and the checksum first ([`hardening.md`](hardening.md), "Verifying a release").

**What is in it.** A minimal Debian (no desktop, no compiler, no mail server), the `seshat` package, systemd-networkd
(DHCP on every wired interface), time synchronisation, `cloud-init` (see below), an SSH server that accepts keys
only, the QEMU guest agent and Open VM Tools. **What is not:** the Device Tracker portal
([`device-tracker-portal.md`](device-tracker-portal.md)) and the edge collector ([`edge.md`](edge.md)). The portal is
meant for people outside the collectors' network and runs as a different user with its own key on purpose, so it does
not belong on the same machine; install its package on a separate host. Edges are installed on the remote sites'
own hosts.

**Sizing.** 2 vCPUs and 2 GiB of memory are the starting point (the OVA asks for exactly that); give it more for
high event rates ([`inputs/`](inputs)). The disk grows with your data (below).

**Licences and sources.** The image is Debian: its packages (the Linux kernel, GNU tools, systemd, GRUB and the rest)
are under their own licences, many of them the GPL and LGPL, and their licence texts are in the image under
`/usr/share/doc/<package>/copyright`. `/usr/share/seshat-appliance/packages.txt` lists every installed package with its
exact version and the source package and version it was built from, and `/etc/seshat-appliance-release` names the
Debian archive snapshot (`DEBIAN_SNAPSHOT`) the image was built from. The corresponding sources of those versions are
available from Debian's archive at snapshot.debian.org for that date. Seshat itself is under the licence in its
`LICENSE` file (also in the image, `/usr/share/doc/seshat/LICENSE`).

### Import

Proxmox VE (the qcow2; storage and bridge names are yours):

```sh
qm create 9000 --name seshat --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci \
  --agent enabled=1 --serial0 socket --ostype l26
qm importdisk 9000 seshat-appliance_<version>_amd64.qcow2 local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0 --boot order=scsi0
qm start 9000
```

Or the OVA: `qm importovf 9000 seshat-appliance_<version>_amd64.ova local-lvm`. For SSH keys and a fixed address use
Proxmox's cloud-init drive (`qm set 9000 --ide2 local-lvm:cloudinit --ciuser admin --sshkeys keys.pub --ipconfig0
ip=192.0.2.20/24,gw=192.0.2.1`); the appliance reads it like any NoCloud seed, and the keys go to the user you name
with `--ciuser` (`admin` here).

**Secure Boot.** Leave the VM on the default SeaBIOS firmware, or, for UEFI, turn Secure Boot off. Proxmox: with
`--bios ovmf`, create the EFI disk without the pre-enrolled keys (`--efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0`),
because OVMF's default keys enforce Secure Boot. Hyper-V generation 2: clear *Enable Secure Boot* in the VM's
firmware settings. VMware: leave *Secure Boot* unchecked under *VM Options > Boot Options*. libvirt/QEMU: use an OVMF
build without enrolled keys.

KVM with libvirt: `virt-install --name seshat --memory 2048 --vcpus 2 --import --disk
path=seshat-appliance_<version>_amd64.qcow2,bus=virtio --network bridge=br0 --osinfo debian13 --graphics none`.

VMware: *File > Deploy OVF Template* (ESXi: *Create / Register VM > Deploy a virtual machine from an OVF or OVA
file*) and pick the `.ova`. VirtualBox: *File > Import Appliance*. The OVA presents an LSI Logic SCSI disk and an
Intel E1000 network adapter, which every one of them offers; switch to paravirtual devices afterwards if you wish
(the kernel has the drivers). The disk controllers tried at release time are virtio-blk, virtio-scsi and LSI Logic
SCSI; SATA and NVMe drivers are in the initial RAM disk and are expected to work, but are not part of the release
test.

### First boot

1. The VM gets an address by DHCP (IPv4, and IPv6 router advertisements). On its first boot it makes what must be
   unique per machine: the secret key that seals stored credentials, the SSH host keys, the machine id and a
   one-time **setup token**. None of them is in the image, so two VMs from one image share nothing.
2. The VM console (and the serial console, 115200 baud) shows the address and the token above the login prompt:

   ```
    Seshat appliance <version>

    Console:  http://192.0.2.20:8080

    First-run setup: open the console from a trusted network and enter this one-time
    setup token to create the administrator:

        0f3a...   (48 characters)
   ```

3. Open that address from a trusted network, enter the token and create the administrator
   (`POST /api/setup`, [`security.md`](security.md)). Once the administrator exists the token disappears from the
   console and from the disk, and the console says the setup is complete.

There is **no password and no SSH key in the image**: root is locked, no account can sign in on the console, and the
SSH server has no key to accept. Complete the setup promptly, and keep the VM on a network where only people you
trust can reach port 8080 until you have put TLS in front of it ([`hardening.md`](hardening.md)): the console speaks
plain HTTP.

### A shell, a fixed address, your keys: cloud-init

For anything beyond the console the appliance uses `cloud-init` with a **NoCloud** seed: a small disk (or the
cloud-init drive of your hypervisor) labelled `cidata` that holds `user-data`, `meta-data` and, if you want a fixed
address, `network-config`. With no seed, `cloud-init` stays out of the way. Example `user-data`:

```yaml
#cloud-config
ssh_authorized_keys:
  - ssh-ed25519 AAAA... you@example.com
```

The key goes to the user `debian` (passwordless `sudo`; SSH root login and password logins stay off). Every VM made
from the image is called `seshat` until you set another name: `meta-data` is `instance-id: seshat-1` and, to name
the VM, `local-hostname: seshat-east`. A static address goes in `network-config`:

```yaml
version: 2
ethernets:
  nic:
    match: { name: "en*" }
    addresses: [192.0.2.20/24]
    routes: [{ to: 0.0.0.0/0, via: 192.0.2.1 }]
    nameservers: { addresses: [192.0.2.53] }
```

Make the seed with `genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data network-config`
and attach it as a CD-ROM (or use the hypervisor's own cloud-init feature). The seed is read on the first boot of
a VM; give a new `instance-id` to apply a changed one.

**Your own setup token or settings.** `write_files` in `user-data` can write `/etc/seshat/seshat.env` before Seshat
starts: the service waits for `cloud-init` to finish writing when a seed is present, and what `seshat.env` holds
wins over everything the appliance generated.

```yaml
write_files:
  - path: /etc/seshat/seshat.env
    permissions: '0600'
    content: |
      SESHAT_SETUP_TOKEN=choose-a-random-token-of-at-least-32-characters
```

The console then says that the token you configured is in use (it does not print it), and the generated one is
ignored and deleted once the administrator exists. Remove the line from `seshat.env` afterwards. (Writing the file
replaces the shipped example; `/usr/share/doc/seshat/seshat.env.example` has it.)

Everything in this guide that says `/etc/seshat/...` works as on any host with the package: edit
`/etc/seshat/seshat.env`, then `systemctl restart seshat`.

### Ports

| Port | Use | Open it to |
|---|---|---|
| 8080/tcp | the console and API (HTTP) | your administrators, preferably through a TLS proxy |
| 162/udp | SNMP traps | the devices that send them |
| 514/udp, 514/tcp | syslog | the devices that send it |
| 2055, 4739, 6343/udp | NetFlow, IPFIX, sFlow, only when enabled in `seshat.env` | your exporters |
| 22/tcp | SSH, keys only | your administrators |

The appliance has no host firewall; restrict these at the hypervisor or the network ([`hardening.md`](hardening.md),
"Listener exposure and firewall rules").

### Data, the disk and backups

* Seshat's data (the database, destination queues, MIB uploads) is `/var/lib/seshat`, mode 0700, on the
  root partition. The secret key is `/etc/seshat/secret.env`; the settings are `/etc/seshat/seshat.env`.
* **Disk space.** Enlarge the virtual disk in the hypervisor and reboot: the root partition and file system grow
  into the new space at boot, nothing else to do.
* **A separate data disk** keeps the data when you replace the image. Add a second virtual disk, then, *before* you
  create the administrator:

  ```sh
  systemctl stop seshat
  mkfs.ext4 -L seshat-data /dev/sdb              # the new, empty disk (check its name with lsblk)
  echo 'LABEL=seshat-data /var/lib/seshat ext4 defaults,noatime 0 2' >> /etc/fstab
  mount /var/lib/seshat && chown seshat:seshat /var/lib/seshat && chmod 0700 /var/lib/seshat
  systemctl start seshat
  ```

* **Backups** follow [`hardening.md`](hardening.md), section 9: the data directory (stop the service for a copy, or
  take a hypervisor snapshot; with the guest agent the file system is frozen consistently) and `seshat.env`; the
  **secret key separately**, and test a restore. A hypervisor snapshot or backup of the whole VM captures both, so
  protect it like the live system.

### Updating

* **Seshat itself**: download the package of the newer release, check it against `SHA256SUMS`, and on the VM run
  `apt install ./seshat_<version>-1_amd64.deb`. Settings, key and data are kept, the service restarts and the
  migrations run (the same as "Upgrade" above). Take a backup first.
* **Debian**: the VM is configured for Debian's package archives. `apt update && apt full-upgrade` brings security
  updates, then reboot when the kernel changed (after a kernel upgrade the boot menu's second entry, "previous kernel", boots the one before; until then that entry has nothing to boot). Nothing
  is installed or restarted automatically.
* **Replacing the image**: deploy the new release's image next to the old one, stop `seshat` on both, copy
  `/var/lib/seshat` and `/etc/seshat/secret.env` (and `seshat.env`) to the new VM (or attach the old VM's data disk),
  fix ownership (`chown -R seshat:seshat /var/lib/seshat`), start `seshat`, then retire the old VM. With a separate data
  disk this is: detach it, attach it to the new VM, mount it.

### If something is wrong

* Boot messages and the login prompt are on the VM console and, at 115200 baud, on the serial port. The GRUB menu
  waits 3 seconds; edit the entry (`e`) to boot into a shell by adding `init=/bin/bash` when you have lost access:
  whoever controls the hypervisor controls the VM, as with any VM.
* `journalctl -u seshat` (the journal is kept across reboots), `systemctl status seshat`, `systemctl --failed`.
* The console banner is written by `seshat-appliance-banner.service`; the one-time work of the first boot by
  `seshat-appliance-firstboot.service`; the disk growth by `seshat-appliance-grow.service`.

