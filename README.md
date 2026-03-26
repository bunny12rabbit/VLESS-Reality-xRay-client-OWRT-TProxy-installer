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

## Quick install

Run this on the router:

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO>/main/install.sh && chmod +x /tmp/install.sh && /tmp/install.sh
