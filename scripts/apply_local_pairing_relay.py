#!/usr/bin/env python3
"""Integrate LocalPairingRelay into StikDebug's JIT and GPS tunnel paths."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
JIT_PATH = ROOT / "StikDebug/Device/JITEnableContext.swift"
LOCATION_PATH = ROOT / "StikDebug/Device/IdeviceFFIBridge.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one exact match, found {count}")
    return text.replace(old, new, 1)


def regex_replace_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError(f"{label}: expected one regex match, found {count}")
    return updated


def patch_jit() -> None:
    text = JIT_PATH.read_text()

    text = replace_once(
        text,
        """    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        var endpointLease: RemotePairingEndpointLease?

        mutating func free() {
            if let handshake {
                rsd_handshake_free(handshake)
                self.handshake = nil
            }
            if let adapter {
                adapter_free(adapter)
                self.adapter = nil
            }
            endpointLease = nil
        }
    }
""",
        """    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        var endpointLease: RemotePairingEndpointLease?
        var relayLease: LocalPairingRelayLease?

        mutating func free() {
            if let handshake {
                rsd_handshake_free(handshake)
                self.handshake = nil
            }
            if let adapter {
                adapter_free(adapter)
                self.adapter = nil
            }
            endpointLease = nil
            relayLease = nil
        }
    }
""",
        "TunnelHandles relay lease",
    )

    text = replace_once(
        text,
        """    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var endpointLease: RemotePairingEndpointLease?
""",
        """    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var endpointLease: RemotePairingEndpointLease?
    private var relayLease: LocalPairingRelayLease?
""",
        "JIT context relay property",
    )

    text = replace_once(
        text,
        """        if let adapter {
            adapter_free(adapter)
        }
        endpointLease = nil
    }

    private func makeError""",
        """        if let adapter {
            adapter_free(adapter)
        }
        endpointLease = nil
        relayLease = nil
    }

    private func makeError""",
        "JIT deinit relay cleanup",
    )

    new_create_tunnel = r'''    private func createTunnel(hostname: String) throws -> TunnelHandles {
        let pairingFile = try getPairingFile()
        defer { rp_pairing_file_free(pairingFile) }

        var failures: [String] = []
        let discovered = try? RemotePairingEndpointResolver.resolve()

        if let discovered,
           discovered.endpoint.interfaceName != "bridge100",
           discovered.endpoint.host != LocalPairingRelayFactory.hotspotEndpoint.host {
            do {
                return try withExtendedLifetime(discovered) {
                    var tunnel = try createTunnel(
                        hostname: hostname,
                        pairingFile: pairingFile,
                        endpoint: discovered.endpoint
                    )
                    tunnel.endpointLease = discovered
                    return tunnel
                }
            } catch let directError as NSError {
                failures.append("Direct peer-to-peer failed: \(directError.localizedDescription)")
                routeLog("Direct peer-to-peer tunnel failed: \(directError.localizedDescription)")
            }
        }

        if let discovered,
           discovered.endpoint.interfaceName == "bridge100"
            || discovered.endpoint.host == LocalPairingRelayFactory.hotspotEndpoint.host {
            do {
                routeLog(
                    "Remote Pairing is advertised on bridge100; trying source-bound local relay to \(discovered.endpoint.displayName)"
                )
                return try createRelayedTunnel(
                    hostname: hostname,
                    pairingFile: pairingFile,
                    target: discovered.endpoint
                )
            } catch let relayError as NSError {
                failures.append("Local hotspot relay failed: \(relayError.localizedDescription)")
                routeLog("Local hotspot relay failed: \(relayError.localizedDescription)")
            }
        }

        do {
            return try createTunnel(
                hostname: hostname,
                pairingFile: pairingFile,
                endpoint: RemotePairingEndpoint(
                    host: DeviceConnectionContext.targetIPAddress,
                    port: 49152
                )
            )
        } catch let vpnError as NSError {
            failures.append("Configured VPN target failed: \(vpnError.localizedDescription)")
            routeLog("Configured VPN target failed: \(vpnError.localizedDescription)")
        }

        do {
            return try createRelayedTunnel(
                hostname: hostname,
                pairingFile: pairingFile,
                target: LocalPairingRelayFactory.hotspotEndpoint
            )
        } catch let relayError as NSError {
            failures.append("Local hotspot relay failed: \(relayError.localizedDescription)")
            throw makeError(
                failures.joined(separator: "\n\n"),
                code: relayError.code
            )
        }
    }

    private func createRelayedTunnel(
        hostname: String,
        pairingFile: OpaquePointer,
        target: RemotePairingEndpoint
    ) throws -> TunnelHandles {
        let relay = try LocalPairingRelayFactory.start(target: target)

        return try withExtendedLifetime(relay) {
            var tunnel = try createTunnel(
                hostname: hostname,
                pairingFile: pairingFile,
                endpoint: relay.endpoint
            )
            tunnel.relayLease = relay
            routeLog(
                "Local hotspot relay connected via \(relay.endpoint.displayName); "
                    + "source \(LocalPairingRelayFactory.localDevVPNSourceAddress), "
                    + "target \(target.displayName)"
            )
            return tunnel
        }
    }
'''

    text = regex_replace_once(
        text,
        r"    private func createTunnel\(hostname: String\) throws -> TunnelHandles \{.*?\n    \}\n\n(?=    private func createTunnel\(\n        hostname: String,)",
        new_create_tunnel.rstrip("\n"),
        "JIT tunnel fallback chain",
    )

    text = replace_once(
        text,
        """        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        var newEndpointLease: RemotePairingEndpointLease?
        var finalError: NSError?
""",
        """        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        var newEndpointLease: RemotePairingEndpointLease?
        var newRelayLease: LocalPairingRelayLease?
        var finalError: NSError?
""",
        "JIT temporary relay lease",
    )

    text = replace_once(
        text,
        """            newAdapter = newTunnel.adapter
            newHandshake = newTunnel.handshake
            newEndpointLease = newTunnel.endpointLease
""",
        """            newAdapter = newTunnel.adapter
            newHandshake = newTunnel.handshake
            newEndpointLease = newTunnel.endpointLease
            newRelayLease = newTunnel.relayLease
""",
        "JIT capture relay lease",
    )

    text = replace_once(
        text,
        """        endpointLease = nil

        adapter = newAdapter
        handshake = newHandshake
        endpointLease = newEndpointLease
""",
        """        endpointLease = nil
        relayLease = nil

        adapter = newAdapter
        handshake = newHandshake
        endpointLease = newEndpointLease
        relayLease = newRelayLease
""",
        "JIT retain relay lease",
    )

    JIT_PATH.write_text(text)


def patch_location() -> None:
    text = LOCATION_PATH.read_text()

    text = replace_once(
        text,
        """private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?
    static var endpointLease: RemotePairingEndpointLease?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        endpointLease = nil
    }
}
""",
        """private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?
    static var endpointLease: RemotePairingEndpointLease?
    static var relayLease: LocalPairingRelayLease?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        endpointLease = nil
        relayLease = nil
    }
}
""",
        "Location relay lease",
    )

    replacement = r'''    func createProvider(endpoint: RemotePairingEndpoint) throws -> UnsafeMutablePointer<IdeviceFfiError>? {
        try DeviceSocketAddress.withSockAddr(endpoint: endpoint) { address, addressLength in
            tunnel_create_rppairing(
                address,
                addressLength,
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    func createRelayedProvider(target: RemotePairingEndpoint) throws -> UnsafeMutablePointer<IdeviceFfiError>? {
        let relay = try LocalPairingRelayFactory.start(target: target)
        let providerError = try withExtendedLifetime(relay) {
            try createProvider(endpoint: relay.endpoint)
        }
        if providerError == nil {
            LocationSimulationState.relayLease = relay
        }
        return providerError
    }

    var providerCreated = false
    let discovered = try? RemotePairingEndpointResolver.resolve()

    if let discovered,
       discovered.endpoint.interfaceName != "bridge100",
       discovered.endpoint.host != LocalPairingRelayFactory.hotspotEndpoint.host {
        do {
            let providerError = try withExtendedLifetime(discovered) {
                try createProvider(endpoint: discovered.endpoint)
            }
            if let providerError {
                idevice_error_free(providerError)
                LocationSimulationState.cleanup()
            } else {
                LocationSimulationState.endpointLease = discovered
                providerCreated = true
            }
        } catch {
            LocationSimulationState.cleanup()
        }
    }

    if !providerCreated,
       let discovered,
       discovered.endpoint.interfaceName == "bridge100"
        || discovered.endpoint.host == LocalPairingRelayFactory.hotspotEndpoint.host {
        do {
            if let providerError = try createRelayedProvider(target: discovered.endpoint) {
                idevice_error_free(providerError)
                LocationSimulationState.cleanup()
            } else {
                providerCreated = true
            }
        } catch {
            LocationSimulationState.cleanup()
        }
    }

    if !providerCreated {
        do {
            let configuredEndpoint = RemotePairingEndpoint(host: deviceIP, port: 49152)
            if let providerError = try createProvider(endpoint: configuredEndpoint) {
                idevice_error_free(providerError)
                LocationSimulationState.cleanup()
            } else {
                providerCreated = true
            }
        } catch {
            LocationSimulationState.cleanup()
        }
    }

    if !providerCreated {
        do {
            if let providerError = try createRelayedProvider(
                target: LocalPairingRelayFactory.hotspotEndpoint
            ) {
                idevice_error_free(providerError)
                LocationSimulationState.cleanup()
                return LocationSimulationStatus.providerCreate
            }
            providerCreated = true
        } catch {
            LocationSimulationState.cleanup()
            return LocationSimulationStatus.providerCreate
        }
    }

    guard providerCreated else {
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }
'''

    text = regex_replace_once(
        text,
        r"    var discoveryLease = try\? RemotePairingEndpointResolver\.resolve\(\).*?\n    LocationSimulationState\.endpointLease = discoveryLease\n",
        replacement,
        "Location tunnel fallback chain",
    )

    LOCATION_PATH.write_text(text)


def main() -> None:
    patch_jit()
    patch_location()
    print("LocalPairingRelay integration applied successfully.")


if __name__ == "__main__":
    main()
