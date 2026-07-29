# gSlapper Wallpaper for Noctalia

`nomadcxx/gslapper` adds image and video wallpapers to Noctalia v5. Its combined
picker can assign one file to every output or a different file to each
connector.

Video playback uses [gSlapper](https://github.com/Nomadcxx/gSlapper) instead of
mpvpaper. gSlapper uses GStreamer rather than libmpv; its README documents lower
CPU, memory, and GPU use than mpvpaper. Tests cover Niri, Hyprland, and Sway.

![gSlapper wallpaper picker](gslapper/thumbnail.webp)

## Requirements

Install [gSlapper](https://github.com/Nomadcxx/gSlapper) 1.5.2 or newer,
`find`, `gst-launch-1.0`, `pkill`, and `socat`.

## Install

Add this repository as a custom plugin source in Noctalia:

1. Open **Settings → Plugins → Sources**.
2. Choose **Add custom repository**.
3. Enter `https://github.com/Nomadcxx/noctalia-gslapper`.
4. Open **Settings → Plugins → Install** and select **gSlapper Wallpaper**.

Or install it from a shell:

```sh
noctalia msg plugins source add gslapper git https://github.com/Nomadcxx/noctalia-gslapper
noctalia msg plugins enable nomadcxx/gslapper
```

See the [plugin README](gslapper/README.md) for the bar-widget steps,
configuration, commands, and runtime side effects.

Run the panel pagination check from the repository root:

```sh
lua tests/panel-selftest.lua
```
