import XCTest
import CoreBluetooth
@testable import PulseLoop

/// A ring the phone is already linked to (Settings > Bluetooth) never advertises, so the pairing list
/// reaches it through `retrieveConnectedPeripherals(withServices:)` instead. These pin the two halves of
/// that path that are pure: which services each family is looked up by, and that a lookup hit — presented
/// to the registry as if it had advertised exactly those services — is claimed by the right family.
@MainActor
final class SystemConnectedDiscoveryTests: XCTestCase {
    func testLuckRingIsLookedUpByItsProtocolService() {
        XCTAssertEqual(LuckRingCoordinator.systemConnectedLookupServices, [CBUUID(string: "F618")])
    }

    func testFamiliesOptInExplicitly() {
        // Only families that are known to be held at the iOS level opt in; everyone else stays scan-only.
        let optedIn = RingBLEClient.coordinators.filter { !$0.systemConnectedLookupServices.isEmpty }
        XCTAssertEqual(optedIn.map { $0.deviceType }, [.luckRing])
    }

    func testLookupHitIsClaimedByLuckRing() {
        // The TK18 as `retrieveConnectedPeripherals` returns it: its name plus the services it was found by.
        let adv = AdvertisementInfo(serviceUUIDs: LuckRingCoordinator.systemConnectedLookupServices, manufacturerData: nil)
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "TK18", advertisement: adv), .luckRing)
        // Even a sibling with an unknown name is claimed, because the service alone is family-exclusive.
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "Ring", advertisement: adv), .luckRing)
    }

    func testDiscoveredRingDefaultsToScanned() {
        let ring = RingBLEClient.DiscoveredRing(
            id: UUID(), name: "TK18", rssi: -60, isLikelyRing: true, deviceType: .luckRing, wearableModelID: nil
        )
        XCTAssertFalse(ring.isSystemConnected)
    }
}
