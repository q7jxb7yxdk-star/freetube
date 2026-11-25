# FFmpeg-iOS-Lame provenance

The Swift package and original binary configuration come from [FFmpeg-iOS-Lame 0.0.6-b20230730-000000](https://github.com/kewlbear/FFmpeg-iOS-Lame/tree/1808fa5a1263c5e216646cd8421fc7dcb70520cc). Its binary targets used the release assets tagged `v0.0.6-b20230416-184420`.

The local `avcodec` and `avutil` XCFrameworks retain the original headers, codecs, and archive members. For the iOS and iOS Simulator arm64 slices, 21 `libavcodec.a` objects and 3 `libavutil.a` objects with common symbols were recompiled from [FFmpeg a3f49168dc](https://github.com/FFmpeg/FFmpeg/tree/a3f49168dcbf3ad7c60db065f40af60427a55a96) with the original configuration and Xcode 27.2 Clang. The build adds `-fno-common` as in the [FFmpeg Darwin fix](https://ffmpeg.org/pipermail/ffmpeg-devel/2025-May/343169.html). The x86_64 simulator slices are the original binaries.

The included LGPL notice applies to the vendored package and libraries.
