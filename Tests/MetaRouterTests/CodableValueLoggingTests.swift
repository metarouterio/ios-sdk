import XCTest
@testable import MetaRouter

final class CodableValueLoggingTests: XCTestCase {
    
    // MARK: - toAny() Tests
    
    func testToAnyString() {
        let value = CodableValue.string("hello")
        let result = value.toAny()
        XCTAssertTrue(result is String)
        XCTAssertEqual(result as? String, "hello")
    }
    
    func testToAnyInt() {
        let value = CodableValue.int(42)
        let result = value.toAny()
        XCTAssertTrue(result is Int)
        XCTAssertEqual(result as? Int, 42)
    }
    
    func testToAnyDouble() {
        let value = CodableValue.double(3.14)
        let result = value.toAny()
        XCTAssertTrue(result is Double)
        XCTAssertEqual(result as? Double, 3.14)
    }
    
    func testToAnyBool() {
        let value = CodableValue.bool(true)
        let result = value.toAny()
        XCTAssertTrue(result is Bool)
        XCTAssertEqual(result as? Bool, true)
    }
    
    func testToAnyNull() {
        let value = CodableValue.null
        let result = value.toAny()
        XCTAssertTrue(result is String)
        XCTAssertEqual(result as? String, "null")
    }
    
    func testToAnyArray() {
        let value = CodableValue.array([
            .string("hello"),
            .int(42),
            .bool(true)
        ])
        let result = value.toAny()
        XCTAssertTrue(result is [Any])
        
        guard let array = result as? [Any] else {
            XCTFail("Expected array")
            return
        }
        
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0] as? String, "hello")
        XCTAssertEqual(array[1] as? Int, 42)
        XCTAssertEqual(array[2] as? Bool, true)
    }
    
    func testToAnyObject() {
        let value = CodableValue.object([
            "name": .string("John"),
            "age": .int(30),
            "active": .bool(true)
        ])
        let result = value.toAny()
        XCTAssertTrue(result is [String: Any])
        
        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary")
            return
        }
        
        XCTAssertEqual(dict["name"] as? String, "John")
        XCTAssertEqual(dict["age"] as? Int, 30)
        XCTAssertEqual(dict["active"] as? Bool, true)
    }
    
    func testToAnyNestedStructure() {
        let value = CodableValue.object([
            "user": .object([
                "name": .string("Alice"),
                "scores": .array([.int(95), .int(87), .int(92)])
            ]),
            "metadata": .object([
                "timestamp": .int(1234567890),
                "valid": .bool(true)
            ])
        ])
        
        let result = value.toAny()
        guard let dict = result as? [String: Any] else {
            XCTFail("Expected dictionary")
            return
        }
        
        // Check nested user object
        guard let user = dict["user"] as? [String: Any] else {
            XCTFail("Expected user dictionary")
            return
        }
        XCTAssertEqual(user["name"] as? String, "Alice")
        
        guard let scores = user["scores"] as? [Any] else {
            XCTFail("Expected scores array")
            return
        }
        XCTAssertEqual(scores.count, 3)
        XCTAssertEqual(scores[0] as? Int, 95)
        
        // Check nested metadata object
        guard let metadata = dict["metadata"] as? [String: Any] else {
            XCTFail("Expected metadata dictionary")
            return
        }
        XCTAssertEqual(metadata["timestamp"] as? Int, 1234567890)
        XCTAssertEqual(metadata["valid"] as? Bool, true)
    }
    
    // MARK: - cleanDescription Tests
    
    func testCleanDescriptionBasic() {
        let dict: [String: CodableValue] = [
            "name": .string("John"),
            "age": .int(30),
            "price": .double(19.99),
            "active": .bool(true)
        ]
        
        let description = dict.cleanDescription
        
        // Verify it doesn't contain CodableValue wrappers
        XCTAssertFalse(description.contains("CodableValue"))
        XCTAssertFalse(description.contains(".string"))
        XCTAssertFalse(description.contains(".int"))
        
        // Verify it contains the actual values
        XCTAssertTrue(description.contains("John"))
        XCTAssertTrue(description.contains("30"))
        XCTAssertTrue(description.contains("19.99"))
        XCTAssertTrue(description.contains("true"))
    }
    
    func testCleanDescriptionEmpty() {
        let dict: [String: CodableValue] = [:]
        let description = dict.cleanDescription
        XCTAssertTrue(description.contains("[:]") || description.contains("{}"))
    }
    
    func testCleanDescriptionWithNestedObjects() {
        let dict: [String: CodableValue] = [
            "user": .object([
                "name": .string("Alice"),
                "age": .int(25)
            ]),
            "tags": .array([.string("swift"), .string("ios")])
        ]
        
        let description = dict.cleanDescription
        
        // Verify no CodableValue wrappers
        XCTAssertFalse(description.contains("CodableValue"))
        XCTAssertFalse(description.contains(".string"))
        XCTAssertFalse(description.contains(".int"))
        XCTAssertFalse(description.contains(".array"))
        XCTAssertFalse(description.contains(".object"))
        
        // Verify values are present
        XCTAssertTrue(description.contains("Alice"))
        XCTAssertTrue(description.contains("25"))
        XCTAssertTrue(description.contains("swift"))
        XCTAssertTrue(description.contains("ios"))
    }
    
    func testCleanDescriptionWithNull() {
        let dict: [String: CodableValue] = [
            "value": .null,
            "name": .string("test")
        ]
        
        let description = dict.cleanDescription
        
        XCTAssertTrue(description.contains("null"))
        XCTAssertTrue(description.contains("test"))
    }
    
    // MARK: - Real-world Use Case Tests
    
    func testTrackingPropertiesConversion() {
        // Simulate what happens in analytics tracking
        let properties: [String: CodableValue] = [
            "product_id": .string("abc123"),
            "price": .double(29.99),
            "quantity": .int(2),
            "in_stock": .bool(true),
            "categories": .array([.string("electronics"), .string("phones")]),
            "metadata": .object([
                "sku": .string("PHN-001"),
                "vendor": .string("Apple")
            ])
        ]
        
        // Verify it looks clean when printed
        let description = properties.cleanDescription
        
        // Should not contain "CodableValue" in the string representation
        XCTAssertFalse(description.contains("CodableValue"))
        XCTAssertFalse(description.contains(".string"))
        XCTAssertFalse(description.contains(".int"))
        XCTAssertFalse(description.contains(".double"))
        XCTAssertFalse(description.contains(".bool"))
        
        // Should contain the actual values
        XCTAssertTrue(description.contains("abc123"))
        XCTAssertTrue(description.contains("29.99"))
        XCTAssertTrue(description.contains("2"))
        XCTAssertTrue(description.contains("true"))
    }
}

