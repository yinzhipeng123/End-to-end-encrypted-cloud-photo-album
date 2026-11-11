"""Create artificial files for the explicitly authorized test-album probe only."""
import base64
import pathlib
import struct

host = pathlib.Path(__file__).resolve().parents[2]
if not (host / "pubspec.yaml").is_file() or not (host / "windows").is_dir():
    raise RuntimeError("Windows host root not found")
root = host.parent / ".local/acceptance/sync-platform/artificial-source"
for parent in [root, *root.parents]:
    if parent.exists() and parent.resolve() != parent.absolute():
        raise RuntimeError("Redirected fixture path rejected")
root.mkdir(parents=True, exist_ok=True)


def chunk(tag, data):
    return tag + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b"")


def group(tag, data):
    return chunk(b"LIST", tag + data)


photo = root / "artificial-photo.png"
if not photo.exists():
    with photo.open("xb") as stream:
        stream.write(base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="))

video = root / "artificial-video-over-50MB.avi"
if not video.exists():
    w, h, n, fps = 1024, 768, 22, 10
    size = w * h * 3
    avih = struct.pack("<14I", 1000000 // fps, size * fps, 0, 0x10, n, 0, 1, size, w, h, 0, 0, 0, 0)
    strh = struct.pack("<4s4sIHH8I4h", b"vids", b"DIB ", 0, 0, 0, 0, 1, fps, 0, n, size, 0xffffffff, 0, 0, 0, w, h)
    strf = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, size, 0, 0, 0, 0)
    hdrl = group(b"hdrl", chunk(b"avih", avih) + group(b"strl", chunk(b"strh", strh) + chunk(b"strf", strf)))
    total = 12 + len(hdrl) + 12 + n * (size + 8) + 8 + n * 16
    with video.open("xb") as stream:
        stream.write(b"RIFF" + struct.pack("<I", total - 8) + b"AVI " + hdrl)
        stream.write(b"LIST" + struct.pack("<I", 4 + n * (size + 8)) + b"movi")
        index = bytearray()
        for i in range(n):
            stream.write(chunk(b"00db", bytes((32 + i * 4, 80, 160 - i * 3)) * (w * h)))
            index.extend(struct.pack("<4sIII", b"00db", 0x10, 4 + i * (size + 8), size))
        stream.write(chunk(b"idx1", index))

print({"artificialPhotoBytes": photo.stat().st_size,
       "artificialVideoBytes": video.stat().st_size, "userMediaRead": False})
