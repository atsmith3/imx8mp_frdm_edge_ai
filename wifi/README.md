# WiFi on i.MX8MP Freedom Board (IW612 / SDIO)

This guide covers connecting the i.MX8MP Freedom Board to WiFi using `nmcli`.

**Board:** i.MX8MP Freedom Board (imx8mpfrdm)  
**WiFi module:** NXP IW612 (connected via SDIO)  
**OS:** Linux 6.18.2-1.0.0

---

## Table of Contents

1. [Verify the Hardware Is Detected](#1-verify-the-hardware-is-detected)
2. [Connect to WiFi with nmcli](#2-connect-to-wifi-with-nmcli)
3. [Verify Connectivity](#3-verify-connectivity)
4. [Boot Persistence](#4-boot-persistence)
5. [Troubleshooting](#5-troubleshooting)

---

## 1. Verify the Hardware Is Detected

Confirm the driver and firmware loaded correctly:

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

Expected output (state will be `DOWN` before connecting):

```
4: mlan0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN ...
```

If either check fails, see [Troubleshooting](#5-troubleshooting).

---

## 2. Connect to WiFi with nmcli

Scan for available networks:

```bash
nmcli device wifi list
```

Expected output:

```
IN-USE  BSSID              SSID      MODE   CHAN  RATE        SIGNAL  SECURITY
        xx:xx:xx:xx:xx:xx  WIFI      Infra  11    195 Mbit/s  72      WPA2
        ...
```

Connect to a network:

```bash
nmcli device wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
```

On success:

```
Device 'mlan0' successfully activated with '...'
```

Verify the connection and assigned IP:

```bash
nmcli
```

Expected output for `mlan0`:

```
mlan0: connected to YOUR_SSID
        "mlan0"
        wifi (wlan_sdio), XX:XX:XX:XX:XX:XX, hw, mtu 1500
        ip4 default
        inet4 192.168.x.x/24
        route4 192.168.x.0/24 metric 600
        route4 default via 192.168.x.1 metric 600
```

---

## 3. Verify Connectivity

Confirm end-to-end internet connectivity via the WiFi interface:

```bash
ping -c 4 -I mlan0 8.8.8.8
```

Expected output:

```
4 packets transmitted, 4 received, 0% packet loss
```

---

## 4. Boot Persistence

NetworkManager saves connection profiles to `/etc/NetworkManager/system-connections/` and restores them automatically on every boot. No additional configuration is required.

To list saved profiles:

```bash
nmcli connection show
```

To add a second network (selected automatically when the primary is out of range):

```bash
nmcli device wifi connect "SECOND_SSID" password "SECOND_PASSWORD"
```

---

## 5. Troubleshooting

### mlan0 shows as `unavailable`

Check whether wpa_supplicant is running:

```bash
systemctl status wpa_supplicant
```

It should be `active (running)`. If it has failed, check the journal:

```bash
journalctl -u wpa_supplicant -n 30
```

### Cannot connect — wrong password or SSID not found

Rescan to confirm the network is visible:

```bash
nmcli device wifi list
```

Delete the saved profile and reconnect with the correct credentials:

```bash
nmcli connection delete "YOUR_SSID"
nmcli device wifi connect "YOUR_SSID" password "YOUR_PASSWORD"
```

### Kernel modules not loaded

If `lsmod | grep moal` returns nothing, the driver did not load. Check dmesg for errors:

```bash
dmesg | grep -iE 'moal|mlan|iw612|sdio' | head -20
```

### WiFi interfaces

The IW612 driver (`moal`) exposes three interfaces:

| Interface | Purpose |
|-----------|---------|
| `mlan0` | Station mode (connects to an access point) |
| `uap0` | Soft access point (host your own hotspot) |
| `wfd0` | Wi-Fi Direct / P2P |

This guide configures `mlan0` only.
