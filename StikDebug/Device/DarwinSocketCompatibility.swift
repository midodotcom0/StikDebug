//
//  DarwinSocketCompatibility.swift
//  StikDebug
//
//  Darwin exposes SOCK_STREAM as Int32, while Glibc exposes an enum whose
//  rawValue is Int32. This tiny compatibility property lets the relay keep one
//  source expression across both platforms.
//

#if canImport(Darwin)
extension Int32 {
    var rawValue: Int32 { self }
}
#endif
