# Source

The blocks and the collision tests were copied from Mantel:

- Repository: https://github.com/ytchou/mantel
- Commit: `30a991648106d75ec42ab5f47b55ffea6fde1b2a` (the app was then named TopNotch)

| Here | There |
|---|---|
| `blocks/nowplaying/` | `Blocks/NowPlaying/` |
| `blocks/rename/` | `Blocks/Rename/` |
| `blocks/shelf/` | `Blocks/Shelf/` |
| `tests/collisions/Tests/CollisionTests/` | `Packages/NotchKit/Tests/BothBlocksTests/` |

`Sources/`, `Tests/` and `manifest.json` of each block are unchanged apart
from the rename to Mantel. Each `Package.swift` was rewritten to take the kit
by URL, or from `$MANTEL`.
The collision tests read the manifests from `blocks/<id>/` and register the
blocks as installed.
