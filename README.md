# VLESS-Reality-xRay-client-OWRT-TProxy-installer
Installer for OpenWrt / GL.iNet routers that sets up:

- Xray
- TProxy transparent interception
- VLESS + REALITY outbound
- XHTTP or TCP transport
- Split tunneling
- Persistent init scripts
- Post-install validation

Designed for fresh router setup where you want to install the whole working Xray + TProxy stack in one run.

## Features

- Installs required dependencies with `opkg`
- Installs `xray-core` from repo or direct `.ipk` URL
- Prompts for all required connection data
- Generates `/etc/xray/config.json`
- Creates `/etc/init.d/xray`
- Creates `/etc/init.d/xray-tproxy`
- Enables and starts services
- Runs automatic post-install validation
- Includes a validation menu option for checking the setup again after reboot

## Supported transport options

- `xhttp`
- `tcp`

## Requirements

- OpenWrt / GL.iNet router
- Root shell access
- Working `opkg`
- Public internet access during installation

## What the installer asks for

- Server address / domain
- Server port
- UUID
- Reality public key
- Reality short ID
- SNI / server name
- Transport type (`xhttp` or `tcp`)

### If `xhttp` is selected

- XHTTP path
- XHTTP mode

### If `tcp` is selected

- Flow

## Installed files

The installer creates or updates these files:

- `/etc/xray/config.json`
- `/etc/init.d/xray`
- `/etc/init.d/xray-tproxy`

## Validation

After installation, the script automatically validates:

- Xray service status
- Xray TProxy enabled state
- Policy routing rule for `fwmark 0x111`
- Routing table `111`
- `XRAY` iptables mangle chain
- `PREROUTING` hooks to `XRAY`
- Listener on port `12345`
- Running Xray process

You can also run validation again later from the installer menu.

## Notes

- The installer can optionally disable and remove `sing-box` if present
- The installer backs up existing Xray files before overwriting them
- The split tunneling list is embedded in the installer template

## Usage after reboot

Run the installer again and choose:

- `2) Validate installed stack`

## Quick install

Run this on the router:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO>/main/install.sh
chmod +x /tmp/install.sh
/tmp/install.sh
