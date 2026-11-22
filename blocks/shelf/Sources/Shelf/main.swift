import BlockKit
import ShelfCore

// The block's entry point: runs `ShelfBlock` on fd 3 until the app sends
// `quit` or closes the socket. The block itself is in ShelfCore.
await ShelfBlock.main()
