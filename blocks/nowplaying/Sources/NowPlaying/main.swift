import BlockKit
import NowPlayingCore

// The block's entry point: runs `TrackBlock` on fd 3 until the app sends
// `quit` or closes the socket. The block itself is in NowPlayingCore.
await TrackBlock.main()
