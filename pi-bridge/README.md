# Pi Zero serial-to-network bridge (ser2net)

Your CNC controller is USB-only (plain grbl/grblHAL), so the Pi attached to the
CNC turns its USB serial port into a raw TCP socket. The gSender container —
running on your Docker host elsewhere — connects to that socket using gSender's
built-in **Ethernet** connection mode.

```
CNC  --USB-->  Pi (ser2net :23)  --TCP/LAN-->  gSender container  -->  browser
```

Why this works: gSender's "Ethernet" connect opens a plain TCP socket and
exchanges newline-delimited text — the exact grbl/grblHAL serial protocol, just
over the network. ser2net pipes those bytes to/from the real serial port.

---

## 1. Give the Pi a fixed IP address

gSender validates the target as a **numeric IPv4 address** — hostnames and
`*.local` won't work. Add a DHCP reservation for the Pi's MAC on your router, or
set a static IP. Note the address (e.g. `192.168.1.50`).

> A Pi Zero W / Zero 2 W is **WiFi-only** (no Ethernet jack). WiFi works but is
> less robust during a job; for wired reliability add a USB-OTG Ethernet adapter.

## 2. Install ser2net

```bash
sudo apt update && sudo apt install -y ser2net
```

(Current Raspberry Pi OS ships ser2net v4, which uses the YAML config here.)

## 3. Find the CNC serial device

Plug the CNC into the Pi, then:

```bash
ls -l /dev/serial/by-id/
```

Copy the `usb-...` path — it's stable across reboots, unlike `ttyUSB0`/`ttyACM0`.

## 4. Configure and start

1. Copy `ser2net.yaml` from this folder to `/etc/ser2net.yaml`.
2. Edit the `connector:` line — set your `/dev/serial/by-id/...` path (and the
   baud if your board isn't 115200).
3. Enable + start:

```bash
sudo systemctl enable --now ser2net
sudo systemctl restart ser2net
systemctl status ser2net          # expect: active (running)
ss -ltn | grep ':23'              # expect: a listener on 0.0.0.0:23
```

## 5. Verify from the Docker host

Confirm the Docker host can reach the bridge before involving gSender:

```bash
# opens the socket and sends a grbl status query; you should see a response
printf '?\r\n' | nc <pi-ip> 23
```

A grbl/grblHAL reply (e.g. `<Idle|MPos:...>` or a `Grbl 1.1` banner) means the
whole chain is good.

## 6. Connect in gSender

In the gSender web UI: **Settings → Connection**
- set the **IP** to the Pi's address (the octet boxes),
- set the **Ethernet port** to `23` (or whatever you chose).

Then open the **Connect** dropdown and click the **Ethernet (port 23)** entry.
gSender opens the TCP socket, auto-detects grbl vs grblHAL from the stream, and
you're connected.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| **Connection timeout** | Wrong IP/port, ser2net not running, or a firewall. Confirm `nc <pi-ip> 23` connects from the Docker host. |
| **Connects, but no firmware detected** | grbl prints its banner on reset; if ser2net holds the serial port open between clients the banner isn't re-sent. gSender's polling usually still detects it — if not, power-cycle the controller right after connecting. |
| **Garbled data / never detects** | The accepter must be `tcp` (raw), **not** `telnet`, and the baud must match the controller. |
| **Resets mid-job** | If your board auto-resets on DTR and that's a problem, you can suppress it — ask and we'll tune the `connector` options. |

> Keep this on the LAN only — don't port-forward 23 to the internet. gSender's
> TCP stream is unauthenticated.
