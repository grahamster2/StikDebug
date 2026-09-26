//
//  LocationSimulator.swift
//  Drift
//
//  Talks to the device's DVT location simulation service over its own RSD
//  tunnel. Every call must run on `LocationSimulator.queue`.
//

import Foundation
import idevice

enum LocationSimulator {
    static let queue = DispatchQueue(label: "drift.location-sim", qos: .userInitiated)

    enum Status {
        static let ok: Int32 = 0
        static let invalidIP: Int32 = 1
        static let pairingRead: Int32 = 2
        static let providerCreate: Int32 = 3
        static let remoteServer: Int32 = 9
        static let locationSimulation: Int32 = 10
        static let locationSet: Int32 = 11
        static let locationClear: Int32 = 12
    }

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    static func describe(_ code: Int32) -> String {
        switch code {
        case Status.invalidIP: return "The target IP address in Settings is not valid."
        case Status.pairingRead: return "The pairing file could not be read. Import it again in Settings."
        case Status.providerCreate: return "Couldn't reach the device. Make sure LocalDevVPN is connected."
        case Status.remoteServer, Status.locationSimulation:
            return "The developer disk image isn't ready yet. Wait for it to mount, then try again."
        case Status.locationSet: return "The device rejected the location update."
        case Status.locationClear: return "Couldn't restore the real location."
        default: return "Unknown error."
        }
    }

    /// Sets the device's reported location, reconnecting once if the session dropped.
    static func set(latitude: Double, longitude: Double) -> Int32 {
        if let locationSimulation {
            if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(ffiError)
                cleanup()
            } else {
                return Status.ok
            }
        }

        let connectCode = connect()
        guard connectCode == Status.ok else { return connectCode }

        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            cleanup()
            return Status.locationSet
        }
        return Status.ok
    }

    /// Restores the device's real location and closes the session. Connects first
    /// if needed, so this also works after the app was relaunched mid-simulation.
    static func clear() -> Int32 {
        if locationSimulation == nil {
            let connectCode = connect()
            guard connectCode == Status.ok else { return connectCode }
        }
        let ffiError = location_simulation_clear(locationSimulation)
        cleanup()
        if let ffiError {
            idevice_error_free(ffiError)
            return Status.locationClear
        }
        return Status.ok
    }

    private static func connect() -> Int32 {
        cleanup()

        let tunnel: (adapter: OpaquePointer, handshake: OpaquePointer)
        do {
            tunnel = try DeviceTunnel.createTunnel(hostname: "DriftLocation")
        } catch let error as NSError {
            switch error.code {
            case -18: return Status.invalidIP
            case -17: return Status.pairingRead
            default: return Status.providerCreate
            }
        }
        adapter = tunnel.adapter
        handshake = tunnel.handshake

        if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(ffiError)
            cleanup()
            return Status.remoteServer
        }

        if let ffiError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(ffiError)
            cleanup()
            return Status.locationSimulation
        }
        // The location simulation handle takes ownership of the remote server.
        remoteServer = nil
        return Status.ok
    }

    private static func cleanup() {
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
    }
}
