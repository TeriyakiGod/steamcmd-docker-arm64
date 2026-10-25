# steamcmd-docker-arm64

Run [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) and x86 dedicated game servers on **arm64** machines, such as Oracle Cloud Ampere A1, Raspberry Pi 4/5, AWS Graviton and Apple-silicon Linux VMs.

SteamCMD and most game servers are only built for x86. The image runs them through the [FEX](https://github.com/FEX-Emu/FEX) emulator, which translates x86 and x86-64 code to arm64 as it runs.

- **Nothing to compile.** FEX comes prebuilt from the official FEX PPA. Builds take minutes, not an hour.
- **Picks the fastest FEX build for your CPU** (armv8.0, armv8.2 or armv8.4) when the container starts.
- **Verified downloads.** The FEX packages are checked against the PPA's signed index, and the x86 root filesystem against a pinned SHA-256.
- **Runs as a non-root user** (`steam`, uid 1000), with no passwords baked into the image.

## Requirements

- An arm64 (aarch64) Linux host with Docker.
- A kernel with **4K memory pages**. FEX does not run on 16K-page kernels. See [Troubleshooting](#troubleshooting) for the Raspberry Pi 5 fix.

## Quick start

```bash
docker run -it --rm teriyakigod/steamcmd:arm64
```

This opens the interactive `Steam>` prompt. The first start updates SteamCMD itself, which takes a minute.

Any arguments that start with `+` go straight to SteamCMD:

```bash
docker run --rm -v steam-games:/data teriyakigod/steamcmd:arm64 \
  +force_install_dir /data/myserver +login anonymous +app_update 896660 validate +quit
```

## Where files go

| Path in container        | What it holds                                   | Mount it to…                    |
| ------------------------ | ----------------------------------------------- | ------------------------------- |
| `/data`                  | Game server files (`+force_install_dir /data/…`) | keep installed games            |
| `/home/steam/steamcmd`   | SteamCMD and its self-updates                   | skip the update on every start  |

Without `+force_install_dir`, SteamCMD installs apps into `/home/steam/steamcmd/steamapps/common/<game>`.

Named volumes work without any extra steps. If you **bind-mount a host directory**, it must be writable by uid 1000:

```bash
mkdir -p ./games
sudo chown 1000:1000 ./games
docker run --rm -v "$PWD/games:/data" teriyakigod/steamcmd:arm64 +force_install_dir /data/myserver ...
```

An empty bind mount on `/home/steam/steamcmd` gets SteamCMD unpacked into it on first start.

## Running a game server

Use the `fex` command to start an x86 or x86-64 program inside the container:

```bash
docker run -d --name valheim -p 2456-2457:2456-2457/udp -v steam-games:/data \
  -w /data/valheim -e LD_LIBRARY_PATH=/data/valheim/linux64 -e SteamAppId=892970 \
  teriyakigod/steamcmd:arm64 \
  fex ./valheim_server.x86_64 -nographics -batchmode -name "My server" -port 2456 \
      -world Dedicated -password change-me-please -savedir /data/valheim-saves
```

[`examples/docker-compose.yml`](examples/docker-compose.yml) has the same setup as a Compose file, with separate install and run steps.

Shell scripts that ship with servers (`start_server.sh`, etc.) often call other x86 programs. Run them with the x86 bash from the emulated root filesystem, so everything they start also runs under FEX:

```bash
docker run ... teriyakigod/steamcmd:arm64 fex /bin/bash ./start_server.sh
```

### Commands

| Command                       | What it does                                 |
| ----------------------------- | -------------------------------------------- |
| *(none)*                      | Interactive SteamCMD prompt                  |
| `+login anonymous …`          | SteamCMD with those arguments                |
| `steamcmd [args…]`            | Same as above                                |
| `fex <program> [args…]`       | Run an x86/x86-64 program under FEX          |
| any other command, e.g. `bash` | Run it as a normal arm64 command (debugging) |

### Environment variables

| Variable       | Default                | Meaning                                                      |
| -------------- | ---------------------- | ------------------------------------------------------------ |
| `FEX_VARIANT`  | detected from the CPU  | Force a FEX build: `armv8.0`, `armv8.2` or `armv8.4`         |
| `STEAMCMD_DIR` | `/home/steam/steamcmd` | Where SteamCMD lives                                         |
| `FEX_*`        | FEX defaults           | Any [FEX option](https://github.com/FEX-Emu/FEX/wiki), e.g. `FEX_SILENTLOG=0` |

## Game compatibility

Whether a particular server runs, and how fast, depends on FEX rather than on this image. Earlier versions of this project were used for [Palworld](https://github.com/yumusb/palworld-server-docker-arm) and Project Zomboid servers. People in [#10](https://github.com/TeriyakiGod/steamcmd-docker-arm64/issues/10) could not get Counter-Strike 2 running. Windows-only servers need Wine, which this image does not include.

Emulation costs CPU time, so expect to need more cores than the game's x86 requirements suggest. If you get a server working (or not), please open an issue so the list can grow.

## Building it yourself

```bash
git clone https://github.com/TeriyakiGod/steamcmd-docker-arm64.git
cd steamcmd-docker-arm64
make build          # = docker buildx build --platform linux/arm64 --load -t steamcmd-arm64:test .
make test           # unit tests + smoke tests against the built image
make test-full      # also downloads a small Steam app end to end
make lint           # shellcheck + hadolint
```

You can build on an x86_64 PC too, as long as qemu-user binfmt is set up (`docker run --privileged --rm tonistiigi/binfmt --install arm64`). The downloads run natively, so the build takes a few minutes. Testing there is partial: FEX's 32-bit mode doesn't work under qemu-user, so `make test` skips the i386 and SteamCMD checks on non-arm64 Docker hosts. Run the tests on a real arm64 machine, or let CI do it, for full coverage.

Build arguments:

| Argument         | Default                    | Meaning                                                     |
| ---------------- | -------------------------- | ----------------------------------------------------------- |
| `FEX_VERSION`    | `latest`                   | FEX PPA package version, e.g. `2610-1~n`                     |
| `ROOTFS_URL`     | FEX's Ubuntu 24.04 rootfs  | x86 root filesystem (SquashFS) from rootfs.fex-emu.gg        |
| `ROOTFS_SHA256`  | matches the default URL    | Update this together with `ROOTFS_URL`                       |
| `UBUNTU_VERSION` | `24.04`                    | Base image. The FEX packages are built for this release      |

To move to a newer root filesystem, pick an Ubuntu entry from [RootFS_links.json](https://rootfs.fex-emu.gg/RootFS_links.json), then update `ROOTFS_URL` and `ROOTFS_SHA256` in the `Dockerfile`.

## Troubleshooting

**`the kernel uses 16384-byte pages, but FEX needs 4K pages`**
Raspberry Pi 5 on Raspberry Pi OS uses a 16K-page kernel by default. Add this line to `/boot/firmware/config.txt` and reboot:

```
kernel=kernel8.img
```

The old `<jemalloc>: Unsupported system page size` crash had the same cause.

**`… is not writable by uid 1000`**
A bind-mounted host directory is owned by someone else. Run `sudo chown -R 1000:1000 <dir>` on the host, or use a named volume.

**`this image needs an arm64 (aarch64) host`**
On x86_64 you don't need emulation. Use a regular SteamCMD image such as [`steamcmd/steamcmd`](https://hub.docker.com/r/steamcmd/steamcmd).

**No output when the container starts**
Use `-it` for the interactive prompt. Without a terminal, SteamCMD waits for input that never comes. For unattended use, pass `+…` commands ending in `+quit`.

**The server crashes or is very slow**
Try a lower FEX build with `-e FEX_VARIANT=armv8.0`, and check the [FEX compatibility list](https://github.com/FEX-Emu/FEX/wiki). Server-specific problems usually belong upstream with FEX.

## How it works

```
arm64 host ─ Docker ─ Ubuntu 24.04 arm64 container
                        ├─ FEX (arm64)            /opt/fex/armv8.{0,2,4}/
                        ├─ x86 Ubuntu rootfs      /opt/fex-rootfs/x86   (FEX_ROOTFS)
                        └─ SteamCMD (x86, 32-bit) /home/steam/steamcmd
```

FEX overlays the x86 root filesystem, so x86 programs find their own libraries there, while everything else (`/home`, `/data`, `/tmp`) is the normal container filesystem. The image doesn't need binfmt_misc or privileged mode: the entrypoint starts x86 programs through `FEX` directly.

## Links

- [SteamCMD documentation](https://developer.valvesoftware.com/wiki/SteamCMD)
- [Dedicated server app IDs](https://developer.valvesoftware.com/wiki/Dedicated_Servers_List)
- [FEX emulator](https://github.com/FEX-Emu/FEX)
- [Docker Hub image](https://hub.docker.com/r/teriyakigod/steamcmd)
