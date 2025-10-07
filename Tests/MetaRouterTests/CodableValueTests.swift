import XCTest
@testable import MetaRouter

final class CodableValueTests: XCTestCase {
    
    func testEncodingProducesCleanJSON() throws {
        let properties: [String: CodableValue] = [
            "name": .string("John"),
            "age": .int(30),
            "price": .double(19.99),
            "active": .bool(true),
            "tags": .array([.string("swift"), .string("ios")]),
            "metadata": .object([
                "version": .string("1.0"),
                "count": .int(5)
            ]),
            "nullValue": .null
        ]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(properties)
        let jsonString = String(data: data, encoding: .utf8)!
        
        // Verify it doesn't contain enum structure
        XCTAssertFalse(jsonString.contains("\"string\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"int\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"double\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"bool\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"array\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"object\""), "Should not contain enum case names")
        XCTAssertFalse(jsonString.contains("\"_0\""), "Should not contain internal enum structure")
        
        // Verify it contains actual values
        XCTAssertTrue(jsonString.contains("\"John\""))
        XCTAssertTrue(jsonString.contains("30"))
        XCTAssertTrue(jsonString.contains("19.99"))
        XCTAssertTrue(jsonString.contains("true"))
        XCTAssertTrue(jsonString.contains("null"))
        
        print("Encoded JSON:\n\(jsonString)")
    }
    
    func testEncodingNestedStructure() throws {
        let event: [String: CodableValue] = [
            "event": .string("product_viewed"),
            "properties": .object([
                "product_id": .string("abc123"),
                "price": .double(29.99),
                "categories": .array([.string("electronics"), .string("phones")])
            ])
        ]
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let jsonString = String(data: data, encoding: .utf8)!
        
        // Should not have double encoding
        XCTAssertFalse(jsonString.contains("\\\""), "Should not have escaped quotes (double encoding)")
        XCTAssertFalse(jsonString.contains("\"_0\""), "Should not contain enum internal structure")
        
        print("Nested structure JSON:\n\(jsonString)")
    }
    
    func testDecodingMatchesEncoding() throws {
        let original: [String: CodableValue] = [
            "name": .string("Alice"),
            "age": .int(25),
            "score": .double(95.5),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .object(["key": .string("value")]),
            "empty": .null
        ]
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([String: CodableValue].self, from: data)
        
        // Verify all values match
        if case .string(let value) = decoded["name"] {
            XCTAssertEqual(value, "Alice")
        } else {
            XCTFail("Expected string")
        }
        
        if case .int(let value) = decoded["age"] {
            XCTAssertEqual(value, 25)
        } else {
            XCTFail("Expected int")
        }
        
        if case .double(let value) = decoded["score"] {
            XCTAssertEqual(value, 95.5)
        } else {
            XCTFail("Expected double")
        }
        
        if case .bool(let value) = decoded["active"] {
            XCTAssertTrue(value)
        } else {
            XCTFail("Expected bool")
        }
        
        if case .null = decoded["empty"] {
            // Success
        } else {
            XCTFail("Expected null")
        }
    }
    
    // MARK: - Original Tests

    
    // Basic Type Tests
    
    func testStringValue() {
        let value: CodableValue = .string("hello")
        
        if case .string(let str) = value {
            XCTAssertEqual(str, "hello")
        } else {
            XCTFail("Expected string value")
        }
    }
    
    func testIntValue() {
        let value: CodableValue = .int(42)
        
        if case .int(let int) = value {
            XCTAssertEqual(int, 42)
        } else {
            XCTFail("Expected int value")
        }
    }
    
    func testDoubleValue() {
        let value: CodableValue = .double(3.14)
        
        if case .double(let double) = value {
            XCTAssertEqual(double, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected double value")
        }
    }
    
    func testBoolValue() {
        let trueValue: CodableValue = .bool(true)
        let falseValue: CodableValue = .bool(false)
        
        if case .bool(let bool) = trueValue {
            XCTAssertTrue(bool)
        } else {
            XCTFail("Expected true bool value")
        }
        
        if case .bool(let bool) = falseValue {
            XCTAssertFalse(bool)
        } else {
            XCTFail("Expected false bool value")
        }
    }
    
    func testArrayValue() {
        let value: CodableValue = .array([.string("hello"), .int(42)])
        
        if case .array(let array) = value {
            XCTAssertEqual(array.count, 2)
            XCTAssertEqual(array[0], .string("hello"))
            XCTAssertEqual(array[1], .int(42))
        } else {
            XCTFail("Expected array value")
        }
    }
    
    func testObjectValue() {
        let value: CodableValue = .object(["key": .string("value")])
        
        if case .object(let object) = value {
            XCTAssertEqual(object["key"], .string("value"))
        } else {
            XCTFail("Expected object value")
        }
    }
    
    func testNullValue() {
        let value: CodableValue = .null
        
        if case .null = value {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected null value")
        }
    }
    
    // Literal Syntax Tests
    
    func testStringLiteral() {
        let value: CodableValue = "hello"
        XCTAssertEqual(value, .string("hello"))
    }
    
    func testIntegerLiteral() {
        let value: CodableValue = 42
        XCTAssertEqual(value, .int(42))
    }
    
    func testFloatLiteral() {
        let value: CodableValue = 3.14
        XCTAssertEqual(value, .double(3.14))
    }
    
    func testBooleanLiteral() {
        let trueValue: CodableValue = true
        let falseValue: CodableValue = false
        
        XCTAssertEqual(trueValue, .bool(true))
        XCTAssertEqual(falseValue, .bool(false))
    }
    
    func testArrayLiteral() {
        let value: CodableValue = ["hello", 42, true]
        let expected: CodableValue = .array([.string("hello"), .int(42), .bool(true)])
        
        XCTAssertEqual(value, expected)
    }
    
    func testDictionaryLiteral() {
        let value: CodableValue = ["key": "value", "number": 42]
        let expected: CodableValue = .object([
            "key": .string("value"),
            "number": .int(42)
        ])
        
        XCTAssertEqual(value, expected)
    }
    
    // MARK: - Value Access Tests
    
    func testValueAccessProperties() {
        // Test string value
        let stringValue: CodableValue = "test"
        XCTAssertEqual(stringValue.stringValue, "test")
        XCTAssertNil(stringValue.intValue)
        
        // Test int value
        let intValue: CodableValue = 42
        XCTAssertEqual(intValue.intValue, 42)
        XCTAssertEqual(intValue.doubleValue, 42.0)
        XCTAssertNil(intValue.stringValue)
        
        // Test double value
        let doubleValue: CodableValue = 3.14
        XCTAssertEqual(doubleValue.doubleValue, 3.14)
        XCTAssertNil(doubleValue.intValue)
        
        // Test bool value
        let boolValue: CodableValue = true
        XCTAssertEqual(boolValue.boolValue, true)
        XCTAssertNil(boolValue.stringValue)
        
        // Test array value
        let arrayValue: CodableValue = [1, "two", true]
        XCTAssertEqual(arrayValue.arrayValue?.count, 3)
        XCTAssertNil(arrayValue.objectValue)
        
        // Test object value
        let objectValue: CodableValue = ["key": "value"]
        XCTAssertEqual(objectValue.objectValue?.count, 1)
        XCTAssertNil(objectValue.arrayValue)
        
        // Test null value
        let nullValue: CodableValue = .null
        XCTAssertTrue(nullValue.isNull)
        XCTAssertNil(nullValue.stringValue)
    }
    
    // MARK: - Type-Safe Conversion Tests
    
    func testTypeSafeConversions() {
        let nested: CodableValue = [
            "string": "value",
            "int": 42,
            "double": 3.14,
            "bool": true,
            "array": [1, 2, 3],
            "object": ["nested": "value"],
            "null": .null
        ]
        
        // Test dictionary conversion
        let dict = nested.toDictionary()
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["string"] as? String, "value")
        XCTAssertEqual(dict?["int"] as? Int, 42)
        XCTAssertEqual(dict?["double"] as? Double, 3.14)
        XCTAssertEqual(dict?["bool"] as? Bool, true)
        XCTAssertEqual((dict?["array"] as? [Int])?.count, 3)
        XCTAssertEqual((dict?["object"] as? [String: String])?["nested"], "value")
        XCTAssertTrue(dict?["null"] is NSNull)
        
        // Test array conversion
        let array: CodableValue = [1, "two", true, ["key": "value"]]
        let converted = array.toArray()
        XCTAssertNotNil(converted)
        XCTAssertEqual(converted?.count, 4)
        XCTAssertEqual(converted?[0] as? Int, 1)
        XCTAssertEqual(converted?[1] as? String, "two")
        XCTAssertEqual(converted?[2] as? Bool, true)
        XCTAssertEqual((converted?[3] as? [String: String])?["key"], "value")
    }
    
    func testNestedDictionaryConversion() {
        let nested: [String: Any] = [
            "brand": "Tropica Plants",
            "category": "Plants",
            "price": 39.99,
            "metadata": [
                "sku": "PL-1005",
                "position": 5
            ] as [String: Any]
        ]
        
        print("Input dictionary: \(nested)")
        
        // First convert to CodableValue
        let converted = CodableValue.convert(nested)
        XCTAssertNotNil(converted)
        
        // Then encode to verify proper nesting
        let encoder = JSONEncoder()
        let data = try! encoder.encode(["properties": converted!])
        let json = String(data: data, encoding: .utf8)!
        print("JSON output: \(json)")
        
        // Should NOT contain escaped quotes (no double serialization)
        XCTAssertFalse(json.contains("\\\""))
        
        // Should be a proper nested structure
        XCTAssertTrue(json.contains(#""brand":"Tropica Plants""#))
        XCTAssertTrue(json.contains(#""metadata":{"sku":"PL-1005""#))
    }
    
    // Equality Tests
    
    func testStringEquality() {
        XCTAssertEqual(CodableValue.string("hello"), CodableValue.string("hello"))
        XCTAssertNotEqual(CodableValue.string("hello"), CodableValue.string("world"))
    }
    
    func testIntEquality() {
        XCTAssertEqual(CodableValue.int(42), CodableValue.int(42))
        XCTAssertNotEqual(CodableValue.int(42), CodableValue.int(43))
    }
    
    func testDoubleEquality() {
        XCTAssertEqual(CodableValue.double(3.14), CodableValue.double(3.14))
        XCTAssertNotEqual(CodableValue.double(3.14), CodableValue.double(3.15))
    }
    
    func testBoolEquality() {
        XCTAssertEqual(CodableValue.bool(true), CodableValue.bool(true))
        XCTAssertEqual(CodableValue.bool(false), CodableValue.bool(false))
        XCTAssertNotEqual(CodableValue.bool(true), CodableValue.bool(false))
    }
    
    func testArrayEquality() {
        let array1: CodableValue = .array([.string("hello"), .int(42)])
        let array2: CodableValue = .array([.string("hello"), .int(42)])
        let array3: CodableValue = .array([.string("hello"), .int(43)])
        
        XCTAssertEqual(array1, array2)
        XCTAssertNotEqual(array1, array3)
    }
    
    func testObjectEquality() {
        let object1: CodableValue = .object(["key": .string("value")])
        let object2: CodableValue = .object(["key": .string("value")])
        let object3: CodableValue = .object(["key": .string("different")])
        
        XCTAssertEqual(object1, object2)
        XCTAssertNotEqual(object1, object3)
    }
    
    func testNullEquality() {
        XCTAssertEqual(CodableValue.null, CodableValue.null)
    }
    
    func testCrossTypeInequality() {
        XCTAssertNotEqual(CodableValue.string("42"), CodableValue.int(42))
        XCTAssertNotEqual(CodableValue.int(1), CodableValue.bool(true))
        XCTAssertNotEqual(CodableValue.double(0.0), CodableValue.null)
    }
    
    // Complex Structure Tests
    
    func testNestedStructures() {
        let complex: CodableValue = [
            "user": [
                "name": "John Doe",
                "age": 30,
                "active": true,
                "settings": [
                    "theme": "dark",
                    "notifications": false
                ]
            ],
            "metadata": [
                "timestamp": 1234567890,
                "version": 1.2
            ],
            "tags": ["user", "premium"],
            "nullField": .null
        ]
        
        if case .object(let root) = complex {
            // Test nested object access
            if case .object(let user) = root["user"] {
                XCTAssertEqual(user["name"], .string("John Doe"))
                XCTAssertEqual(user["age"], .int(30))
                XCTAssertEqual(user["active"], .bool(true))
                
                if case .object(let settings) = user["settings"] {
                    XCTAssertEqual(settings["theme"], .string("dark"))
                    XCTAssertEqual(settings["notifications"], .bool(false))
                } else {
                    XCTFail("Expected settings object")
                }
            } else {
                XCTFail("Expected user object")
            }
            
            // Test array access
            if case .array(let tags) = root["tags"] {
                XCTAssertEqual(tags.count, 2)
                XCTAssertEqual(tags[0], .string("user"))
                XCTAssertEqual(tags[1], .string("premium"))
            } else {
                XCTFail("Expected tags array")
            }
            
            // Test null field
            XCTAssertEqual(root["nullField"], .null)
        } else {
            XCTFail("Expected root object")
        }
    }
    
    func testEmptyCollections() {
        let emptyArray: CodableValue = .array([])
        let emptyObject: CodableValue = .object([:])
        
        if case .array(let array) = emptyArray {
            XCTAssertTrue(array.isEmpty)
        } else {
            XCTFail("Expected empty array")
        }
        
        if case .object(let object) = emptyObject {
            XCTAssertTrue(object.isEmpty)
        } else {
            XCTFail("Expected empty object")
        }
    }
    
    func testLiteralSyntaxWithComplexStructures() {
        let value: CodableValue = [
            "mixed_array": [1, "two", 3.0, true, ["nested"]],
            "nested_object": [
                "level1": [
                    "level2": "deep_value"
                ]
            ]
        ]
        
        if case .object(let root) = value {
            if case .array(let mixedArray) = root["mixed_array"] {
                XCTAssertEqual(mixedArray[0], .int(1))
                XCTAssertEqual(mixedArray[1], .string("two"))
                XCTAssertEqual(mixedArray[2], .double(3.0))
                XCTAssertEqual(mixedArray[3], .bool(true))
                XCTAssertEqual(mixedArray[4], .array([.string("nested")]))
            } else {
                XCTFail("Expected mixed array")
            }
        } else {
            XCTFail("Expected root object")
        }
    }
}