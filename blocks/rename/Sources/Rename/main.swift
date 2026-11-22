import BlockKit
import RenameCore

// Runs the block on fd 3 until the app sends `quit` or closes the socket.
// The block itself is in RenameCore.
await RenameBlock.main()
