#!/usr/bin/env python3
"""Offline consistency checks after `forge build`; no third-party dependencies."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads((ROOT / path).read_text())


manifest = read("launch.json")
assert manifest["kind"] == "univ4_hook"
assert manifest["hook"] == {
    "contract": "JackpotHook",
    "constructorArgs": ["0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"],
    "permissions": ["beforeSwap", "beforeSwapReturnDelta"],
}
assert manifest["token"] == {
    "contract": "PepeIce", "name": "pepes ice", "symbol": "ICE", "decimals": 18
}
assert manifest["pool"] == {
    "pairedCurrency": "0x0000000000000000000000000000000000000000",
    "fee": 3000, "tickSpacing": 60,
    "initialPrice": "79228162514264337593543950336000",
}
for contract, constructor_types in [("PepeIce", []), ("JackpotHook", ["address"])]:
    artifact = read(f"out/{contract}.sol/{contract}.json")
    exported = read(f"docs/abi/{contract}.json")
    assert exported == artifact["abi"], f"Stale ABI: {contract}"
    constructor = next(entry for entry in exported if entry["type"] == "constructor")
    assert [entry["type"] for entry in constructor["inputs"]] == constructor_types
    code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(code) <= 24576
    offset = 0
    while offset < len(code):
        opcode = code[offset]
        assert opcode not in (0xF2, 0xF4, 0xFF), f"Escape-hatch opcode in {contract} at {offset}"
        offset += 1 + (opcode - 0x5F if 0x60 <= opcode <= 0x7F else 0)
print("Manifest, constructor ABIs, ABI exports and runtime opcode checks passed.")
