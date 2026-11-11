"""只读检查 iOS 原生库结构；不能代替 Xcode 构建或设备执行。"""
import hashlib
import json
import struct
import sys
from pathlib import Path

EXPECTED = {
    'libsqlcipher.arm64.ios.dylib': '3ce5dec3e52c008ec33eadfd45ae441ca6c2ca82643cf6fd191a8f228b7192e1',
    'libsqlcipher.arm64.ios_sim.dylib': '4449e5c5078e768bdf6ba874992a5b14770f83876cc84ebda7fa0b4ca3e8d900',
}


def inspect(path):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if path.name not in EXPECTED or digest != EXPECTED[path.name]:
        raise ValueError('二进制 SHA-256 与 sqlite3 3.9.1 记录不符')
    magic, cpu, _, _, commands, _, _, _ = struct.unpack_from('<8I', data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError('不是 ARM64 little-endian Mach-O')
    result = {'file': path.name, 'sha256': digest, 'cpu': 'arm64', 'libraries': []}
    offset = 32
    symbols = set()
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('无效 load command')
        if command == 0x32:  # LC_BUILD_VERSION
            platform, minimum, sdk, _ = struct.unpack_from('<4I', data, offset + 8)
            version = lambda n: f'{n >> 16}.{(n >> 8) & 255}.{n & 255}'
            result.update(platform={2: 'ios', 7: 'ios-simulator'}.get(platform, str(platform)),
                          minimum=version(minimum), sdk=version(sdk))
        if command in (0xC, 0xD):  # LC_LOAD_DYLIB / LC_ID_DYLIB
            start = offset + struct.unpack_from('<I', data, offset + 8)[0]
            name = data[start:data.index(b'\0', start)].decode()
            result['libraries'].append(name)
        if command == 2:  # LC_SYMTAB
            symoff, count, stroff, _ = struct.unpack_from('<4I', data, offset + 8)
            for index in range(count):
                strx, kind, _, _, _ = struct.unpack_from('<IBBHQ', data, symoff + index * 16)
                if kind & 1 and kind & 0xE == 0xE:  # 已定义的外部符号
                    start = stroff + strx
                    symbols.add(data[start:data.index(b'\0', start)].decode())
        offset += size
    required = {'_sqlite3_key', '_sqlite3_open_v2', '_sqlcipher_extra_init'}
    if not required.issubset(symbols):
        raise ValueError('缺少所需 SQLCipher 导出符号')
    result['sqlcipherSymbols'] = sorted(required)
    expected_platform = 'ios-simulator' if 'ios_sim' in path.name else 'ios'
    if result.get('platform') != expected_platform:
        raise ValueError('Mach-O 平台不匹配')
    return result


if __name__ == '__main__':
    print(json.dumps([inspect(Path(arg)) for arg in sys.argv[1:]], indent=2))
