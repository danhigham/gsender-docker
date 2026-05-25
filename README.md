# gsender-docker

Builds [gSender](https://github.com/Sienci-Labs/gsender) as a **headless server
container** and publishes it to GitHub Container Registry, so you can run your
CNC over the network instead of tethering a Raspberry Pi with a display.

This repo does **not** fork gSender. Instead it tracks upstream releases: a
scheduled GitHub Action checks `Sienci-Labs/gsender` for the latest release and
builds an image for that version. No fork to keep in sync, no merge conflicts.

## How it works

```
Sienci-Labs/gsender releases ──poll(daily)──► GitHub Action ──build──► ghcr.io/danhigham/gsender:<version>
                                                                       ghcr.io/danhigham/gsender:latest
```

- `Dockerfile` — multi-stage build. Clones gSender at a given tag, runs its
  production build (`yarn install` → `package-sync` → `build-prod`) to produce
  the headless server in `dist/gsender/`, then assembles a slim Node runtime.
  It builds the *server* only — no Electron, no GUI.
- `.github/workflows/build.yml` — resolves the newest upstream release tag,
  skips the build if that version's image already exists, otherwise builds
  `linux/amd64` and pushes `:<version>` and `:latest` to GHCR.
- `docker-compose.yml` — what you run on the CNC host.

## One-time setup

1. Push this repo to GitHub (`danhigham/gsender-docker`).
2. **Actions → Build gSender image → Run workflow** to kick off the first build
   (or wait for the daily schedule). The first run builds the current latest
   release (`v1.6.1`).
3. After the first successful push, the image package is created under your
   account but defaults to **private**. To `docker pull` it without logging in,
   make it public: GitHub → your profile → **Packages → gsender → Package
   settings → Change visibility → Public**.
   (Or keep it private and `docker login ghcr.io` on the host with a PAT that
   has `read:packages`.)

## Running it on the CNC host

The host is the amd64 box the CNC's USB/serial cable plugs into.

```bash
# grab docker-compose.yml from this repo onto the host, then:
docker compose pull
docker compose up -d
```

Open `http://<host-ip>:8080`. In the web UI, connect to the serial port and
pick your controller (Grbl / grblHAL).

### Pointing at your serial device

Find the device on the host:

```bash
ls -l /dev/serial/by-id/
```

Put the `by-id` path in `docker-compose.yml` under `devices:` (it's stable
across replugs, unlike `ttyUSB0`/`ttyACM0`). The container always sees it as
`/dev/ttyUSB0`.

### Connecting to the CNC over the network (no local serial device)

If the CNC isn't plugged into the Docker host — e.g. it hangs off a separate Pi
acting as a serial-to-network bridge — gSender connects over TCP instead of a
local serial port. Leave `devices:` commented out in `docker-compose.yml`; the
container reaches the bridge as an ordinary outbound LAN connection (the default
bridge network is fine, no `network_mode: host` needed).

gSender's **Ethernet** connection opens a *raw TCP socket* to `IP:port`
(default port `23`) and speaks the grbl/grblHAL protocol over it. In the web UI,
set the bridge's **IP** and **Ethernet port** under **Settings → Connection**,
then click the **Ethernet** entry in the Connect dropdown. The target must be a
**numeric IP** — hostnames aren't accepted.

See [`pi-bridge/`](./pi-bridge/) for the Pi `ser2net` setup that exposes a
USB-only grbl/grblHAL controller as that TCP socket.

### Setting the controller without the UI

The default command runs `--remote` and lets you choose the controller in the
browser. To pin it, override the command in compose:

```yaml
    command: ["node", "bin/gsender", "-H", "0.0.0.0", "-p", "8080",
              "--remote", "--controller", "grblHal",
              "-c", "/data/.cncrc", "-w", "/data/gcode"]
```

## Building locally (optional)

```bash
docker build --build-arg GSENDER_REF=v1.6.1 -t gsender:local .
docker run --rm -p 8080:8080 --device /dev/ttyUSB0 -v gsender-data:/data gsender:local
```

## Notes & caveats

- **amd64 only.** The workflow builds `linux/amd64`. To also target a
  Raspberry Pi / arm64 host, add `linux/arm64` to `platforms:` in the workflow
  (use a native arm runner or expect slow QEMU emulation), and rebuild the
  native modules accordingly.
- **Safety:** Sienci explicitly warns against running a CNC unattended over the
  network. Treat the web UI as trusted-LAN only; don't expose port 8080 to the
  internet.
- Settings, macros and uploaded G-code live in the `gsender-data` volume
  (`/data/.cncrc` + `/data/gcode`). Back it up if you care about it.
- The runtime image is ~740MB: it ships only the compiled server +
  `dist/gsender` + the server's production deps, not the ~1GB of build/frontend
  tooling. It runs the headless server (`bin/gsender`) — no Electron, no X.
