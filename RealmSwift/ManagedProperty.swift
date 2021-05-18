////////////////////////////////////////////////////////////////////////////
//
// Copyright 2021 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import Realm
import Realm.Private

/// @Managed is used to declare properties on Object subclasses which should be
/// managed by Realm.
///
/// Example of usage:
/// ```
/// class MyModel: Object {
///     // A basic property declaration. A property with no
///     // default value supplied will default to `nil` for
///     // Optional types, zero for numeric types, false for Bool,
///     // an empty string/data, and a new random value for UUID
///     // and ObjectID.
///     @Managed var basicIntProperty: Int
///
///     // Custom default values can be specified with the
///     // standard Swift syntax
///     @Managed var intWithCustomDefault: Int = 5
///
///     // Properties can be indexed by passing `indexed: true`
///     // to the initializer.
///     @Managed(indexed: true) var indexedString: String
///
///     // Properties can set as the class's primary key by
///     // passing `primary: true` to the initializer
///     @Managed(primary: true) var _id: ObjectId
///
///     // List and set properties should always be declared
///     // with `: List` rather than `= List()`
///     @Managed var listProperty: List<Int>
///     @Managed var setProperty: MutableSet<MyObject>
///
///     // LinkingObjects properties require setting the source
///     // object link property name in the initializer
///     @Managed(originProperty: "outgoingLink")
///     var incomingLinks: LinkingObjects<OtherModel>
///
///     // Properties which are not marked with @Managed will
///     // be ignored entirely by Realm.
///     var ignoredProperty = true
/// }
/// ```
///
///  Int, Bool, String, ObjectId and Date properties can be indexed by passing
///  `indexed: true` to the initializer. Indexing a property improves the
///  performance of equality queries on that property, at the cost of slightly
///  worse write performance. No other operations currently use the index.
///
///  A property can be set as the class's primary key by passing `primary: true`
///  to the initializer. Compound primary keys are not supported, and setting
///  more than one property as the primary key will throw an exception at
///  runtime. Only Int, String, UUID and ObjectID properties can be made the
///  primary key, and when using MongoDB Realm, the primary key must be named
///  `_id`. The primary key property can only be mutated on unmanaged objects,
///  and mutating it on an object which has been added to a Realm will throw an
///  exception.
///
///  Properties can optionally be given a default value using the standard Swift
///  syntax. If no default value is given, a value will be generated on first
///  access: `nil` for all Optional types, zero for numeric types, false for
///  Bool, an empty string/data, and a new random value for UUID and ObjectID.
///  List and MutableSet properties *should not* be defined by setting them to a
///  default value of an empty List/MutableSet. Doing so will work, but will
///  result in worse performance when accessing objects managed by a Realm.
///  Similarly, ObjectID properties *should not* be initialized to
///  `ObjectID.generate()`, as doing so will result in extra ObjectIDs being
///  generated and then discarded when reading from a Realm.
///
///  If a class has at least one @Managed property, all other properties will be
///  ignored by Realm. This means that they will not be persisted and will not
///  be usable in queries and other operations such as sorting and aggregates
///  which require a managed property.
///
///  @Managed cannot be used anywhere other than as a property on an Object or
///  EmbeddedObject subclass and trying to use it in other places will result in
///  runtime errors.
@propertyWrapper
public struct Managed<Value: _ManagedPropertyType> {
    private var storage: PropertyStorage<Value>

    /// :nodoc:
    @available(*, unavailable, message: "@Managed can only be used as a property on a Realm object")
    public var wrappedValue: Value {
        get { fatalError("called wrappedValue getter") }
        // swiftlint:disable:next unused_setter_value
        set { fatalError("called wrappedValue setter") }
    }

    /// Declares a property which is lazily initialized to the type's default value.
    public init() {
        storage = .unmanagedNoDefault(indexed: false, primary: false)
    }
    /// Declares a property which defaults to the given value.
    public init(wrappedValue value: Value) {
        storage = .unmanaged(value: value, indexed: false, primary: false)
    }

    /// :nodoc:
    public static subscript<EnclosingSelf: ObjectBase>(
        _enclosingInstance observed: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
        ) -> Value {
        get {
            return observed[keyPath: storageKeyPath].get(observed)
        }
        set {
            observed[keyPath: storageKeyPath].set(observed, value: newValue)
        }
    }

    @discardableResult
    internal mutating func initialize(_ object: ObjectBase, key: PropertyKey) -> Value? {
        if case let .unmanaged(value, _, _) = storage, value is MutableRealmCollection {
            storage = .managedCached(value: value, key: key)
            return value
        }
        storage = .managed(key: key)
        return nil
    }

    internal mutating func get(_ object: ObjectBase) -> Value {
        switch storage {
        case let .unmanaged(value, _, _):
            return value
        case .unmanagedNoDefault:
            let value = Value._rlmDefaultValue()
            storage = .unmanaged(value: value)
            return value
        case let .unmanagedObserved(value, _):
            return value
        case let .managed(key):
            let v = Value._rlmGetProperty(object, key)
            if v is MutableRealmCollection {
                storage = .managedCached(value: v, key: key)
            }
            return v
        case let .managedCached(value, _):
            return value
        }
    }

    internal mutating func set(_ object: ObjectBase, value: Value) {
        if value is MutableRealmCollection {
            assign(value: value, to: get(object) as! MutableRealmCollection)
            return
        }
        switch storage {
        case let .unmanagedObserved(_, key):
            let name = RLMObjectBaseObjectSchema(object)!.properties[Int(key)].name
            object.willChangeValue(forKey: name)
            storage = .unmanagedObserved(value: value, key: key)
            object.didChangeValue(forKey: name)
        case .managed(let key), .managedCached(_, let key):
            Value._rlmSetProperty(object, key, value)
        case .unmanaged, .unmanagedNoDefault:
            storage = .unmanaged(value: value, indexed: false, primary: false)
        }
    }

    // Initialize an unmanaged property for observation
    internal mutating func observe(_ object: ObjectBase, property: RLMProperty) {
        let value: Value
        switch storage {
        case let .unmanaged(v, _, _):
            value = v
        case .unmanagedNoDefault:
            value = Value._rlmDefaultValue()
        case .unmanagedObserved, .managed, .managedCached:
            return
        }
        if let value = value as? MutableRealmCollection {
            value.setParent(object, property)
        }
        storage = .unmanagedObserved(value: value, key: PropertyKey(property.index))
    }
}

extension Managed: Decodable where Value: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = try .unmanaged(value: container.decode(Value.self), indexed: false, primary: false)
    }
}

extension Managed: Encodable where Value: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch storage {
        case .unmanaged(let value, _, _):
            try value.encode(to: encoder)
        case .unmanagedObserved(let value, _):
            try value.encode(to: encoder)
        case .unmanagedNoDefault:
            try Value._rlmDefaultValue().encode(to: encoder)
        default:
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Only unmanaged Realm objects can be encoded using automatic Codable synthesis. You must explicitly define encode(to:) on your model class to support managed Realm objects."))
        }
    }
}

/// A type which can be indexed.
///
/// This protocol is merely a tag and declaring additional types as conforming
/// to it will simply result in runtime errors rather than compile-time errors.
public protocol IndexableProperty {}

extension Managed where Value: IndexableProperty {
    /// Declares an indexed property which is lazily initialized to the type's default value.
    public init(indexed: Bool) {
        storage = .unmanagedNoDefault(indexed: indexed)
    }
    /// Declares an indexed property which defaults to the given value.
    public init(wrappedValue value: Value, indexed: Bool) {
        storage = .unmanaged(value: value, indexed: indexed)
    }
}

/// A type which can be made the primary key of an object.
///
/// This protocol is merely a tag and declaring additional types as conforming
/// to it will simply result in runtime errors rather than compile-time errors.
public protocol PrimaryKeyProperty {}

extension Managed where Value: PrimaryKeyProperty {
    /// Declares the primary key property which is lazily initialized to the type's default value.
    public init(primaryKey: Bool) {
        storage = .unmanagedNoDefault(primary: primaryKey)
    }
    /// Declares the primary key property which defaults to the given value.
    public init(wrappedValue value: Value, primaryKey: Bool) {
        storage = .unmanaged(value: value, primary: primaryKey)
    }
}

/// :nodoc:
// Constraining the LinkingObjects initializer to only LinkingObjects require
// doing so via a protocol which only that type conforms to.
public protocol LinkingObjectsProtocol {
    init(fromType: Element.Type, property: String)
    associatedtype Element
}
extension Managed where Value: LinkingObjectsProtocol {
    /// Declares a LinkingObjects property with the given origin property name.
    ///
    /// - param originProperty: The name of the property on the linking object type which links to this object.
    public init(originProperty: String) {
        self.init(wrappedValue: Value(fromType: Value.Element.self, property: originProperty))
    }
}
extension LinkingObjects: LinkingObjectsProtocol {}

// MARK: - Implementation

/// :nodoc:
extension Managed: _DiscoverableManagedProperty where Value: _ManagedPropertyType {
    public static var _rlmType: PropertyType { Value._rlmType }
    public static var _rlmOptional: Bool { Value._rlmOptional }
    public static var _rlmRequireObjc: Bool { false }
    public static func _rlmPopulateProperty(_ prop: RLMProperty) {
        // The label reported by Mirror has an underscore prefix added to it
        // as it's the actual storage rather than the compiler-magic getter/setter
        prop.name = String(prop.name.dropFirst())
        Value._rlmPopulateProperty(prop)
        Value._rlmSetAccessor(prop)
    }
    public func _rlmPopulateProperty(_ prop: RLMProperty) {
        switch storage {
        case let .unmanaged(value, indexed, primary):
            value._rlmPopulateProperty(prop)
            prop.indexed = indexed || primary
            prop.isPrimary = primary
        case let .unmanagedNoDefault(indexed, primary):
            prop.indexed = indexed || primary
            prop.isPrimary = primary
        default:
            fatalError()
        }
    }
}

// The actual storage for modern properties on objects
private enum PropertyStorage<T> {
    // An unmanaged value. This can be either
    case unmanaged(value: T, indexed: Bool = false, primary: Bool = false)

    // The property is unmanaged and does not yet have a value. This state is
    // used if the user does not supply a default value in their model definition
    // and will be converted to the zero/empty value for the type when this
    // property is first used.
    case unmanagedNoDefault(indexed: Bool = false, primary: Bool = false)

    // The property is unmanaged and the parent object has (or previously had)
    // KVO observers, so we performed the additional initialization to set the
    // property key on each property. We do not track indexed/primary in this
    // state because those are needed only for schema discovery.
    case unmanagedObserved(value: T, key: PropertyKey)

    // The property is managed and so only needs to store the key to get/set
    // the value on the parent object.
    case managed(key: PropertyKey)

    // The property is managed and is storing a value which will be returned each
    // time. This is used only for collection properties, which are themselves
    // live objects and so only need to be created once. Caching them is both a
    // performance optimization (creating them involves a few memory allocations)
    // and is required for KVO to work correctly.
    case managedCached(value: T, key: PropertyKey)
}