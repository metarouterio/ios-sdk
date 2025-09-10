import XCTest
@testable import MetaRouter

final class CodableValueTests: XCTestCase {
    
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