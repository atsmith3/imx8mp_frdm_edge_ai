# WiFi Enablement on i.MX8MP Freedom Board (IW612 / SDIO)

This guide explains why the IW612 WiFi module does not work out of the box on a custom Yocto build for the i.MX8MP Freedom Board, and walks through the exact steps to bring it up.

**Board:** i.MX8MP Freedom Board (imx8mpfrdm)  
**WiFi module:** NXP IW612 (connected via SDIO)  
**OS:** Linux 6.18.2-1.0.0, Yocto `imx_full_build`  
**Estimated time:** 10 minutes

---

## Table of Contents

1. [Background](#1-background)
2. [Why WiFi Does Not Work Out of the Box](#2-why-wifi-does-not-work-out-of-the-box)
3. [Verify the Hardware Is Detected](#3-verify-the-hardware-is-detected)
4. [Step 1 Disable the Broken D-Bus wpa_supplicant Service](#4-step-1--disable-the-broken-d-bus-wpa_supplicant-service)
5. [Step 2 Tell NetworkManager to Ignore WiFi Interfaces](#5-step-2--tell-networkmanager-to-ignore-wifi-interfaces)
6. [Step 3 Create the wpa_supplicant Config File](#6-step-3--create-the-wpa_supplicant-config-file)
7. [Step 4 Enable the Per-Interface wpa_supplicant Service](#7-step-4--enable-the-per-interface-wpa_supplicant-service)
8. [Step 5 Add Your WiFi Network Credentials](#8-step-5--add-your-wifi-network-credentials)
9. [Step 6 Reload wpa_supplicant and Connect](#9-step-6--reload-wpa_supplicant-and-connect)
10. [Step 7 Verify Connectivity](#10-step-7--verify-connectivity)
11. [Boot Persistence](#11-boot-persistence)
12. [Troubleshooting](#12-troubleshooting)
13. [Technical Notes](#13-technical-notes)

---

## 1. Background

The i.MX8MP Freedom Board includes an NXP IW612 dual-band WiFi 6 / Bluetooth 5.2 combo module connected over SDIO. The factory OS shipped on the eMMC (`/dev/mmcblk2`) has WiFi working. A custom Yocto build flashed to an SD card (`/dev/mmcblk1`) does **not** - even though the driver, firmware, and hardware are all present and functional.

The fix does **not** require rebuilding the kernel or Yocto image. Everything needed is already on the board.

---

## 2. Why WiFi Does Not Work Out of the Box

Several layered issues prevent WiFi from coming up automatically, even though the hardware is detected:

### Issue 1 - wpa_supplicant is disabled

The `wpa_supplicant.service` unit exists on the system but its systemd preset is `disabled`. NetworkManager (which is running) requires wpa_supplicant to manage WPA/WPA2 associations. Without it, every attempt to use the WiFi interface fails with:

```
Failed to D-Bus activate wpa_supplicant service
```

### Issue 2 - wpa_supplicant is compiled without D-Bus support

Even if you enable and start `wpa_supplicant.service`, it exits immediately. The service is configured to run `wpa_supplicant -u` (D-Bus mode), but this Yocto build compiled wpa_supplicant **without** `CONFIG_CTRL_IFACE_DBUS_NEW`. The `-u` flag is silently ignored and the process exits.

### Issue 3 - iwd cannot start (no CONFIG_RFKILL in kernel)

NetworkManager supports `iwd` as an alternative WiFi backend. The `iwd` binary (`/usr/libexec/iwd`) is present on the system, but the kernel was built without `CONFIG_RFKILL`. The `/dev/rfkill` character device does not exist, and `iwd` requires it to manage radio state. `iwd` starts and immediately exits with:

```
Module rfkill failed to start: -2
D-Bus disconnected, quitting...
```

### The result

The WiFi interfaces `mlan0`, `uap0`, and `wfd0` are created by the driver and appear in `ip link`, but NetworkManager reports them all as `unavailable`. The hardware is working - the management layer is not.

### The solution

Use `wpa_supplicant` in **standalone mode** via the `wpa_supplicant@mlan0.service` per-interface template. This path requires no D-Bus support and no rfkill. DHCP is handled by the `dhcpcd` master daemon, which is already running and enabled at boot.

---

## 3. Verify the Hardware Is Detected

Before making any changes, confirm the driver and firmware loaded correctly. Run:

```bash
lsmod | grep -E 'moal|mlan'
```

Expected output:

```
moal                  901120  3
mlan                  688128  1 moal
```

Confirm the WiFi interface exists:

```bash
ip link show mlan0
```

Expected output (state will be `DOWN` at this point):

```
4: mlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN ...
```

Confirm firmware loaded at boot:

```bash
dmesg | grep -E 'WLAN FW|Register NXP'
```

Expected output:

```
[    7.402182] WLAN FW is active
[    7.578918] Register NXP 802.11 Adapter mlan0
```

If any of these checks fail, the driver or firmware is missing this guide does not cover that case.

---

## 4. Step 1 - Disable the Broken D-Bus wpa_supplicant Service

The default `wpa_supplicant.service` runs in D-Bus mode (`-u`) which does not work on this build. Disable it so it does not interfere:

```bash
systemctl disable wpa_supplicant
systemctl stop wpa_supplicant 2>/dev/null || true
```

Verify it is disabled:

```bash
systemctl is-enabled wpa_supplicant
```

Expected output: `disabled`

---

## 5. Step 2 - Tell NetworkManager to Ignore WiFi Interfaces

NetworkManager will keep trying (and failing) to activate wpa_supplicant for `mlan0`, `uap0`, and `wfd0`. Instruct it to leave these interfaces unmanaged:

```bash
mkdir -p /etc/NetworkManager/conf.d

cat > /etc/NetworkManager/conf.d/wifi-unmanaged.conf << 'EOF'
[device-wifi-unmanaged]
match-device=interface-name:mlan0,interface-name:uap0,interface-name:wfd0
managed=false
EOF
```

Restart NetworkManager to apply:

```bash
systemctl restart NetworkManager
```

Verify the interfaces are now unmanaged:

```bash
nmcli device status
```

Expected output for the WiFi interfaces:

```
mlan0   wifi      unmanaged    --
uap0    wifi      unmanaged    --
wfd0    wifi      unmanaged    --
```

> Ethernet (`eth0`) continues to be managed by NetworkManager and is not affected.

---

## 6. Step 3 - Create the wpa_supplicant Config File

Create the directory and a minimal configuration file for the `mlan0` interface:

```bash
mkdir -p /etc/wpa_supplicant

cat > /etc/wpa_supplicant/wpa_supplicant-mlan0.conf << 'EOF'
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
EOF
```

The `ctrl_interface` line creates a Unix socket at `/run/wpa_supplicant/mlan0` that allows `wpa_cli` to communicate with the daemon to add networks and check status.

---

## 7. Step 4 - Enable the Per-Interface wpa_supplicant Service

The `wpa_supplicant@.service` template already exists on the system. Enable and start it for `mlan0`:

```bash
systemctl enable wpa_supplicant@mlan0.service
systemctl start wpa_supplicant@mlan0.service
```

Verify it is running:

```bash
systemctl status wpa_supplicant@mlan0.service
```

Expected output:

```
* wpa_supplicant@mlan0.service - WPA supplicant daemon (for interface mlan0)
     Loaded: loaded (/usr/lib/systemd/system/wpa_supplicant@.service; enabled)
     Active: active (running) ...
```

You will see this message in the logs - it is harmless:

```
rfkill: Cannot open RFKILL control device
```

wpa_supplicant logs this warning when `/dev/rfkill` is absent, but it continues to operate normally without it.

---

## 8. Step 5 - Add Your WiFi Network Credentials

Use `wpa_passphrase` to generate a config block with a hashed PSK (the plaintext password is **not** stored in the file):

```bash
wpa_passphrase "YOUR_SSID" "YOUR_PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
```

Replace `YOUR_SSID` and `YOUR_PASSWORD` with your actual network name and password.

After running this command, verify the file looks correct:

```bash
cat /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
```

Expected output (PSK hash will differ):

```
ctrl_interface=/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
network={
    ssid="YOUR_SSID"
    #psk="YOUR_PASSWORD"
    psk=a1b2c3d4e5f6...
}
```

The commented `#psk=` line showing the plaintext password can be removed for security:

```bash
sed -i '/#psk=/d' /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
```

---

## 9. Step 6 - Reload wpa_supplicant and Connect

Signal wpa_supplicant to re-read its configuration file:

```bash
wpa_cli -i mlan0 reconfigure
```

wpa_supplicant will immediately attempt to scan and associate. Wait a few seconds, then check the status:

```bash
wpa_cli -i mlan0 status
```

Expected output when connected:

```
bssid=xx:xx:xx:xx:xx:xx
freq=2417
ssid=YOUR_SSID
wpa_state=COMPLETED
ip_address=192.168.x.x
wifi_generation=6
key_mgmt=WPA2-PSK
```

`wpa_state=COMPLETED` means the 802.11 association and WPA2 handshake are done.

If `ip_address` is not populated yet, the `dhcpcd` daemon (already running) will assign one automatically within a few seconds. Check:

```bash
ip addr show mlan0 | grep inet
```

---

## 10. Step 7 - Verify Connectivity

Confirm end-to-end internet connectivity via the WiFi interface:

```bash
ping -c 4 -I mlan0 8.8.8.8
```

Expected output:

```
4 packets transmitted, 4 received, 0% packet loss
```

Confirm a default route is present via `mlan0`:

```bash
ip route show dev mlan0
```

Expected output:

```
default via 192.168.x.1 proto dhcp src 192.168.x.x metric 3004
192.168.x.0/24 proto dhcp scope link src 192.168.x.x metric 3004
```

WiFi is now fully operational.

---

## 11. Boot Persistence

The configuration survives reboots without any additional steps. The two services that start automatically are:

| Service | Role | Enabled at boot |
|---------|------|-----------------|
| `wpa_supplicant@mlan0.service` | 802.11 association and WPA2 handshake | Yes (step 4) |
| `dhcpcd.service` | DHCP on all interfaces, including `mlan0` | Yes (preset) |

**Boot sequence:**

1. `wpa_supplicant@mlan0.service` starts and reads `/etc/wpa_supplicant/wpa_supplicant-mlan0.conf`
2. wpa_supplicant scans, finds your SSID, and completes the WPA2 handshake
3. `mlan0` transitions to `LOWER_UP` (carrier present)
4. `dhcpcd` detects carrier on `mlan0` and requests a DHCP lease
5. `mlan0` receives an IP address and a default route is added

To add a second WiFi network (e.g. a work network in addition to your home network), append another block to the config:

```bash
wpa_passphrase "SECOND_SSID" "SECOND_PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
wpa_cli -i mlan0 reconfigure
```

wpa_supplicant will automatically select the strongest available network.

---

## 12. Troubleshooting

### wpa_supplicant service fails to start

Check the logs:

```bash
journalctl -u wpa_supplicant@mlan0 -n 30
```

If it fails immediately, verify the config file exists and is readable:

```bash
cat /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
```

### wpa_state stays at SCANNING or DISCONNECTED

The SSID or password may be incorrect. The PSK is derived at the time `wpa_passphrase` runs, so a typo requires regenerating:

```bash
# Remove the bad network block and regenerate
wpa_passphrase "YOUR_SSID" "CORRECT_PASSWORD" > /tmp/net.conf
# Append to your config
cat /tmp/net.conf >> /etc/wpa_supplicant/wpa_supplicant-mlan0.conf
wpa_cli -i mlan0 reconfigure
```

Alternatively, scan and check your SSID is visible:

```bash
wpa_cli -i mlan0 scan && sleep 3 && wpa_cli -i mlan0 scan_results
```

### No IP address after association

`dhcpcd` is already running as a master daemon. Check if it is managing `mlan0`:

```bash
ps aux | grep dhcpcd
```

You should see a process like `dhcpcd: [BPF ARP] mlan0 192.168.x.x`. If `mlan0` is not listed, trigger DHCP manually:

```bash
dhcpcd mlan0
```

### mlan0 still shows as unavailable in nmcli

The NetworkManager config may not have been applied. Verify the file exists:

```bash
cat /etc/NetworkManager/conf.d/wifi-unmanaged.conf
```

Then restart NetworkManager and check again:

```bash
systemctl restart NetworkManager
nmcli device status
```

### Kernel modules not loaded

If `lsmod | grep moal` returns nothing, the driver is not loaded. Check dmesg for errors:

```bash
dmesg | grep -iE 'moal|mlan|iw612|sdio' | head -20
```

The modules are in `/lib/modules/$(uname -r)/updates/`. If they are missing for the current kernel version, the out-of-tree driver needs to be rebuilt.

---

## 13. Technical Notes

### Why the factory eMMC OS works

The factory OS (kernel 6.6.36) has `CONFIG_RFKILL=y` compiled into the kernel. This creates `/dev/rfkill`, which allows `iwd` to start. NetworkManager uses `iwd` as its WiFi backend and everything works via the normal code path.

### Why iwd does not work on this Yocto build

`CONFIG_RFKILL` is not set in the kernel config used for this Yocto build:

```bash
zcat /proc/config.gz | grep RFKILL
# CONFIG_RFKILL is not set
```

The `iwd` binary (`/usr/libexec/iwd`) is present, but iwd unconditionally requires `/dev/rfkill` and exits if it is absent.

### Why wpa_supplicant D-Bus mode does not work

The `wpa_supplicant` package was built without `CONFIG_CTRL_IFACE_DBUS_NEW`. You can verify this by checking that `-u` does not appear in the usage text:

```bash
wpa_supplicant --help 2>&1 | grep '\-u'
```

If the flag is absent, the binary was built without D-Bus support.

### Long-term fix (requires Yocto rebuild)

To restore the standard NetworkManager + iwd code path, add `CONFIG_RFKILL=y` to the kernel config fragment for `imx8mpfrdm` in your Yocto layer and rebuild. This is the same configuration the factory eMMC OS uses. Once the kernel has rfkill support:

1. Remove `/etc/NetworkManager/conf.d/wifi-unmanaged.conf`
2. Disable `wpa_supplicant@mlan0.service`
3. Use `nmcli` to manage WiFi connections normally

### WiFi interfaces

The IW612 driver (`moal`) exposes three interfaces:

| Interface | Purpose |
|-----------|---------|
| `mlan0` | Station mode (connects to an access point) |
| `uap0` | Soft access point (host your own hotspot) |
| `wfd0` | Wi-Fi Direct / P2P |

This guide configures `mlan0` only.
