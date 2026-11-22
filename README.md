# mantel-blocks

Blocks for [Mantel](https://github.com/ytchou/mantel), a macOS notch app.
Mantel ships with no blocks; this repository holds three, each its own
Swift package that runs as its own sandboxed process:

| Block | Folder | What it does | Access |
|---|---|---|---|
| Now Playing | `blocks/nowplaying` | Shows the track when the volume or the track changes | none |
| Screenshot Names | `blocks/rename` | Gives each new screenshot a name that says what is in it | `files.screenshots` |
| Shelf | `blocks/shelf` | Holds what you drop on the notch until you drag it out | `files.read` |

`tests/collisions` runs all three in one Mantel runtime, to test what
happens when they want the notch at once. `catalog.json` lists the blocks.
The blocks are MIT licensed (`LICENSE`). `SOURCE.md` names the Mantel
commit they came from.

Needs macOS 26 and Swift 6.2.

## Build and test

```sh
make build
make test
```

The blocks take the kit by URL: `https://github.com/ytchou/mantel.git`,
from `0.1.0`. To build against a Mantel checkout instead, set `MANTEL`:

```sh
MANTEL=~/project/mantel make test
```

Through `make`, `MANTEL` may be relative (to this folder) or start with
`~`; the Makefile makes it absolute. When you call `swift` directly, it must
be an absolute path.

With `MANTEL` set, `make test` also runs the collision tests. They need
it: Mantel's runtime and the blocks must use the same kit, from the same
folder, so the build holds it once. Without `MANTEL` they are skipped.
The collision tests run in debug only (`swift test -c release` is not
supported): they use `@testable import`.

After you set or unset `MANTEL`, run `make clean` once if a build uses the
wrong kit.

## Package

```sh
make package
```

Each block becomes `build/<Name>.mantelblock`, made by the kit's
`package-block.sh`. It is signed ad hoc unless `BLOCK_SIGN_IDENTITY` names
a signing identity. `BLOCK_SIGN_TIMESTAMP=none` signs without a secure
timestamp (no network needed).

## Install

1. Copy the `.mantelblock` package into
   `~/Library/Application Support/Mantel/Blocks`.
2. Quit Mantel and open it again.
3. Open Settings > Blocks. The block waits as New: review it and approve it.

Mantel runs a block only after you approve its exact build. A package
signed ad hoc is approved for that build only; a rebuilt package waits
again. An update must come from the same signer as the installed block.

A block keeps its data and settings by its id (`nowplaying`, `rename`,
`shelf`), so a package of the same id, installed again or updated, finds
them where it left them.

## Screenshot Names and Apple Intelligence

Screenshot Names reads the text in each new screenshot on this Mac and asks
Apple Intelligence, on device, for a short name. Nothing leaves the Mac.
Without Apple Intelligence (not turned on, not supported, or still loading)
it still renames, from the text it read, or with a dated name.
