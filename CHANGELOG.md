# Changelog

## 0.1.0

The first public version. API level 1.

- Machines: macOS, Linux and Windows VMs (UTM), iOS simulators and Android
  emulators, leased as clones of bases; SSH, VNC, simctl, adb and
  screenshots.
- Containers of any image: processes with input written and output read
  from any offset, files (followed as they grow), labels, limits, archives
  and restores, a token of their own for leasing machines, settings for
  every container and per image.
- `GET /v1/capabilities`: the version, API level and features.
- `OSSClient`: the API's types and an async Swift client.
- `oss mcp`: the machine commands as Model Context Protocol tools.
