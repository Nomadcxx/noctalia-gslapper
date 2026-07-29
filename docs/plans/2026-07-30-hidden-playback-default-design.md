# Hidden Playback Default

gSlapper video wallpapers must keep playing unless the user selects a power-saving mode.

The plugin will use the same terms as gSlapper integrations such as Waytrogen:

- `None`: pass no hidden-playback flag
- `Auto Pause`: pass `--auto-pause`
- `Auto Stop`: pass `--auto-stop`

`None` becomes the manifest default and the runtime fallback for missing or invalid settings. Existing users who saved `auto-pause` or `auto-stop` keep their choice.

The service self-test will assert the mapping and default fallback. The README settings table will name `None` as the default.
