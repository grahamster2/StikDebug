//
//  DeviceTunnel.swift
//  Drift
//
//  Trimmed from StikDebug's JITEnableContext: only the RSD tunnel and the
//  developer disk image (cryptex) calls that location simulation needs.
//

import Foundation
import idevice
import Darwin

final class DeviceTunnel {
    static let shared = DeviceTunnel()

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    private let tunnelLock = NSLock()
    private var tunnelConnecting = false
    private var tunnelSemaphore: DispatchSemaphore?
    private var lastTunnelError: NSError?

    private init() {
        let logURL = URL.documentsDirectory.appendingPathComponent("idevice_log.txt")
        var path = Array(logURL.path.utf8CString)
        path.withUnsafeMutableBufferPointer { buffer in
            _ = idevice_init_logger(Info, Debug, buffer.baseAddress)
        }
    }

    // MARK: - Errors

    static func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(domain: "Drift", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func consume(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else { return makeError(fallback) }
        let message = ffiError.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        let error = makeError(message, code: Int(ffiError.pointee.code))
        idevice_error_free(ffiError)
        return error
    }

    // MARK: - Tunnel

    /// Opens an RSD tunnel to the device through LocalDevVPN. Caller owns the handles.
    static func createTunnel(hostname: String) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw makeError("Pairing file not found!", code: -17)
        }

        var pairingFile: OpaquePointer?
        if let ffiError = pairingFileURL.path.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw consume(ffiError, fallback: "Failed to read pairing file!")
        }
        guard let pairingFile else {
            throw makeError("Failed to read pairing file!", code: -17)
        }
        defer { rp_pairing_file_free(pairingFile) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(49152).bigEndian

        let deviceIP = DeviceConnectionContext.targetIPAddress
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw makeError("Failed to parse target IP address.", code: -18)
        }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let ffiError = hostname.withCString { hostname in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &newAdapter,
                        &newHandshake
                    )
                }
            }
        }
        if let ffiError {
            throw consume(ffiError, fallback: "Failed to create tunnel")
        }

        guard let newAdapter, let newHandshake else {
            if let newHandshake { rsd_handshake_free(newHandshake) }
            if let newAdapter { adapter_free(newAdapter) }
            throw makeError("Tunnel was created without valid handles")
        }
        return (newAdapter, newHandshake)
    }

    func startTunnel() throws {
        tunnelLock.lock()
        if tunnelConnecting {
            let waitSemaphore = tunnelSemaphore
            tunnelLock.unlock()

            if let waitSemaphore {
                guard waitSemaphore.wait(timeout: .now() + .seconds(15)) == .success else {
                    throw Self.makeError("Timed out waiting for the tunnel connection", code: -19)
                }
                waitSemaphore.signal()
            }
            if let lastTunnelError {
                throw lastTunnelError
            }
            return
        }

        tunnelConnecting = true
        let completionSemaphore = DispatchSemaphore(value: 0)
        tunnelSemaphore = completionSemaphore
        tunnelLock.unlock()

        var finalError: NSError?
        defer {
            tunnelLock.lock()
            tunnelConnecting = false
            tunnelSemaphore = nil
            lastTunnelError = finalError
            tunnelLock.unlock()
            completionSemaphore.signal()
        }

        let tunnel: (adapter: OpaquePointer, handshake: OpaquePointer)
        do {
            tunnel = try Self.createTunnel(hostname: "Drift")
        } catch let error as NSError {
            finalError = error
            throw error
        }

        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        adapter = tunnel.adapter
        handshake = tunnel.handshake
    }

    private func withTunnel<T>(_ body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
        if adapter == nil || handshake == nil {
            try startTunnel()
        }
        guard let adapter, let handshake else {
            throw Self.makeError("Tunnel is not connected")
        }
        return try body(adapter, handshake)
    }

    // MARK: - Developer disk image

    func isCryptexDDIInstalled() throws -> Bool {
        try withTunnel { adapter, handshake in
            var installed: UnsafeMutablePointer<InstalledCryptexC>?
            if let ffiError = cryptexd_installed_ddi(adapter, handshake, &installed) {
                throw Self.consume(ffiError, fallback: "Failed to query installed DDI cryptex")
            }
            defer { cryptexd_free_installed_cryptex(installed) }
            return installed != nil
        }
    }

    func installCryptexDDI(from directoryPath: String) throws {
        var assets: OpaquePointer?
        if let ffiError = cryptex1_assets_load(directoryPath, &assets) {
            throw Self.consume(ffiError, fallback: "Failed to load DDI cryptex assets")
        }
        guard let assets else {
            throw Self.makeError("DDI cryptex assets were not loaded")
        }
        defer { cryptex1_assets_free(assets) }

        try withTunnel { adapter, handshake in
            if let ffiError = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw Self.consume(ffiError, fallback: "Failed to install DDI cryptex")
            }
        }
    }
}
