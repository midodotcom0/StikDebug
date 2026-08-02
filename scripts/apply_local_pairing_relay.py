#!/usr/bin/env python3
"""Validate and repair the generated LocalPairingRelay integration.

The initial integration is committed on the feature branch. This script is kept
in the IPA workflow as a deterministic guard against the two escaping/spacing
pitfalls that can occur when Swift source is generated through a regex tool.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
JIT_PATH = ROOT / "StikDebug/Device/JITEnableContext.swift"
LOCATION_PATH = ROOT / "StikDebug/Device/IdeviceFFIBridge.swift"
RELAY_PATH = ROOT / "StikDebug/Device/LocalPairingRelay.swift"


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise RuntimeError(f"Missing relay integration marker: {label}")


def patch_jit() -> None:
    text = JIT_PATH.read_text()

    # re.sub interpreted the intended Swift escape sequence as real line breaks
    # in the first generated commit. Convert it back to a normal Swift string.
    text = text.replace(
        'failures.joined(separator: "\n\n")',
        'failures.joined(separator: "\\n\\n")',
    )

    # Preserve a syntactic boundary between the relay helper and the original
    # endpoint-based tunnel overload.
    text = text.replace(
        "    }    private func createTunnel(\n",
        "    }\n\n    private func createTunnel(\n",
    )

    require(text, "var relayLease: LocalPairingRelayLease?", "JIT relay lifetime")
    require(text, "private func createRelayedTunnel(", "JIT relay helper")
    require(
        text,
        'failures.joined(separator: "\\n\\n")',
        "JIT combined diagnostics separator",
    )
    require(
        text,
        "relayLease = newRelayLease",
        "JIT retained relay lease",
    )

    if "    }    private func createTunnel(" in text:
        raise RuntimeError("JIT tunnel overloads are still joined on one line")

    JIT_PATH.write_text(text)


def validate_location() -> None:
    text = LOCATION_PATH.read_text()
    require(text, "static var relayLease: LocalPairingRelayLease?", "GPS relay lifetime")
    require(text, "func createRelayedProvider(", "GPS relay provider")
    require(
        text,
        "LocationSimulationState.relayLease = relay",
        "GPS retained relay lease",
    )


def validate_relay() -> None:
    text = RELAY_PATH.read_text()
    require(text, 'sourceAddress: String = localDevVPNSourceAddress', "source binding")
    require(text, 'RemotePairingEndpoint(host: "172.20.10.1", port: 49152)', "hotspot target")
    require(text, 'static let localDevVPNSourceAddress = "10.7.0.2"', "LocalDevVPN local IP")
    require(text, "bind(upstream", "outbound source bind")
    require(text, "local_pairing_relay.log", "relay diagnostics")


def main() -> None:
    patch_jit()
    validate_location()
    validate_relay()
    print("LocalPairingRelay integration is valid.")


if __name__ == "__main__":
    main()
