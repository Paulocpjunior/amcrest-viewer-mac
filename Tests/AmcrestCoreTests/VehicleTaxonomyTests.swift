import XCTest
@testable import AmcrestCore

final class VehicleTaxonomyTests: XCTestCase {

    func testMatchesVehicleIdentifiers() {
        for id in ["car", "sports_car", "race car", "wheeled_vehicle",
                   "pickup_truck", "tow_truck", "school_bus", "minivan",
                   "motorcycle", "delivery_van", "taxi", "ambulance",
                   "land-vehicle"] {
            XCTAssertTrue(VehicleTaxonomy.isVehicle(id), "deveria ser veículo: \(id)")
        }
    }

    func testRejectsNonVehicles() {
        for id in ["person", "dog", "scarf", "carpet", "cardigan",
                   "tree", "building", "bicycle", "vehicleless_thing"] {
            XCTAssertFalse(VehicleTaxonomy.isVehicle(id), "não deveria ser veículo: \(id)")
        }
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(VehicleTaxonomy.isVehicle("SPORTS_CAR"))
        XCTAssertTrue(VehicleTaxonomy.isVehicle("Truck"))
    }
}
