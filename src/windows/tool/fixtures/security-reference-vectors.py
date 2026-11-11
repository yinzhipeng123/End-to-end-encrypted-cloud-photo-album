"""Independent artificial fixtures. Never run against user vaults or passwords.

Reproduce in an isolated venv with argon2-cffi==25.1.0 and pycryptodome==3.23.0.
The C reference Argon2 and PyCryptodome XChaCha implementations do not use the
App's libsodium backend. Python hashlib supplies the BLAKE2b KDF reference.
"""
import hashlib
import json
import struct
import sys
from pathlib import Path

from argon2.low_level import hash_secret_raw, Type
from Crypto.Cipher import ChaCha20_Poly1305


def derive(password, salt):
    return hash_secret_raw(password.encode('utf-8'), salt, 3, 65536, 1, 32,
                           Type.ID, version=19)


def wrap(key, nonce, aad, plaintext):
    cipher = ChaCha20_Poly1305.new(key=key, nonce=nonce)
    cipher.update(aad)
    encrypted, tag = cipher.encrypt_and_digest(plaintext)
    return encrypted + tag


password = '  synthetic 测试 river carpet 🌄  '
salt = bytes(range(16))
master = bytes(range(32))
catalog = bytes(range(32, 64))
derived = derive(password, salt)
catalog_wrapper = hashlib.blake2b(
    b'', digest_size=32, key=master,
    salt=struct.pack('<Q', 3) + bytes(8), person=b'EPAKDF01' + bytes(8),
).digest()
header = (
    b'EPAVLT01' + struct.pack('<HBBBBHIHHQ', 1, 1, 1, 19, 1, 3, 67108864, 32, 48, 1)
    + bytes(range(16, 32)) + bytes(range(48, 64)) + salt
    + bytes(range(24)) + bytes(range(24, 48)) + struct.pack('<I', 96)
)
assert len(header) == 132
master_ciphertext = wrap(derived, header[80:104],
                         b'EPA/bootstrap/master/v1\x00' + header, master)
catalog_ciphertext = wrap(catalog_wrapper, header[104:128],
                          b'EPA/bootstrap/catalog/v1\x00' + header + master_ciphertext,
                          catalog)

def media_aad(purpose, *contexts):
    return (f'EPA/{purpose}/v1\0'.encode('ascii') + header[32:48]
            + b''.join(struct.pack('<I', len(c)) + c for c in contexts))

purpose_keys = {
    str(purpose): hashlib.blake2b(
        b'', digest_size=32, key=master,
        salt=struct.pack('<Q', purpose) + bytes(8), person=b'EPAKDF01' + bytes(8),
    ).digest() for purpose in (1, 2, 3)
}
resource_context = b'artificial-resource/version-1'
unit_context = b'artificial-unit-0'
resource_key = bytes(range(64, 96))
media_nonce = bytes(range(24))
media_plain = bytes(range(256)) + '人工照片视频资源'.encode('utf-8')
media_reference = {
    'purpose_keys_hex': {str(k): v.hex() for k, v in purpose_keys.items()},
    'resource_context_hex': resource_context.hex(),
    'unit_context_hex': unit_context.hex(),
    'resource_key_hex': resource_key.hex(),
    'nonce_hex': media_nonce.hex(),
    'plaintext_hex': media_plain.hex(),
    'resource_wrap_hex': wrap(purpose_keys['1'], media_nonce,
                             media_aad('resource-key', resource_context), resource_key).hex(),
    'media_aad_hex': media_aad('media-unit', resource_context, unit_context).hex(),
    'media_ciphertext_hex': wrap(resource_key, media_nonce,
                               media_aad('media-unit', resource_context, unit_context), media_plain).hex(),
    'recovery_ciphertext_hex': wrap(purpose_keys['2'], media_nonce,
                                  media_aad('recovery-metadata', resource_context), media_plain).hex(),
}
fixture = {
    'artificial_test_fixture': True,
    'reference': 'argon2-cffi 25.1.0; PyCryptodome 3.23.0; Python hashlib BLAKE2b',
    'password': password,
    'salt_hex': salt.hex(),
    'wrapping_key_hex': derived.hex(),
    'master_hex': master.hex(),
    'catalog_hex': catalog.hex(),
    'catalog_wrapping_key_hex': catalog_wrapper.hex(),
    'bootstrap_hex': (header + master_ciphertext + catalog_ciphertext).hex(),
    'media_reference': media_reference,
}
path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print('Generated artificial independent reference fixture; no user data accessed.')
