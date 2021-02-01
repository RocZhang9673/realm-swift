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

#if SCHEMA_VERSION_3

import Foundation
import RealmSwift

// MARK: - Schema

let schemaVersion = 3

// Changes from previous version:
// rename the `Dog` object to `Pet`
// add a `type` property to `Pet`
// change the `dogs` property on `Person`:
// - rename to `pets`
// - change type to `List<Pet>`

// Renaming tables is not supported yet: https://github.com/realm/realm-cocoa/issues/2491
// The recommended way is to create a new type instead and migrate the old type.
// Here we create `Pet` and migrate its data from `Dog` so simulate renaming the table.

@objc enum PetType: Int, RealmEnum {
    case unspecified
    case dog
    case chicken
    case cow
}

class Pet: Object {
    @objc dynamic var name = ""
    let type = RealmOptional<PetType>()
    convenience init(name: String, type: PetType) {
        self.init()
        self.name = name
        self.type.value = type
    }
}

class Person: Object {
    @objc dynamic var fullName = ""
    @objc dynamic var age = 0
    let pets = List<Pet>()
    convenience init(fullName: String, age: Int) {
        self.init()
        self.fullName = fullName
        self.age = age
    }
}

// MARK: - Migration

// Migration block to migrate from *any* previous version to this version.
let migrationBlock: MigrationBlock = { migration, oldSchemaVersion in
    if oldSchemaVersion < 1 {
        migration.enumerateObjects(ofType: Person.className()) { oldObject, newObject in
            // combine name fields into a single field
            let firstName = oldObject!["firstName"] as! String
            let lastName = oldObject!["lastName"] as! String
            newObject!["fullName"] = "\(firstName) \(lastName)"
        }
    }
    if oldSchemaVersion < 2 {
        migration.enumerateObjects(ofType: Person.className()) { _, newObject in
            // Add a pet to a specific person
            if newObject!["fullName"] as! String == "John Doe" {
                // `Dog` was changed to `Pet` in v2 already, but we still need to account for this
                // if upgrading from pre v2 to v3.
                let dogs = newObject!["pets"] as! List<MigrationObject>
                let marley = migration.create(Pet.className(), value: ["Marley", PetType.dog.rawValue])
                let lassie = migration.create(Pet.className(), value: ["Lassie", PetType.dog.rawValue])
                dogs.append(marley)
                dogs.append(lassie)
            } else if newObject!["fullName"] as! String == "Jane Doe" {
                let dogs = newObject!["pets"] as! List<MigrationObject>
                let toto = migration.create(Pet.className(), value: ["Toto", PetType.dog.rawValue])
                dogs.append(toto)
            }
        }
        let slinkey = migration.create(Pet.className(), value: ["Slinkey", PetType.dog.rawValue])
    }
    if oldSchemaVersion == 2 {
        // This branch is only relevant for version 2. If we are migration from a previous
        // version, we would not be able to access `dogs` since they did not exist back there.
        // Migration from v0 and v1 to v3 is done in the previous blocks.
        // Related issue: https://github.com/realm/realm-cocoa/issues/6263
        migration.enumerateObjects(ofType: Person.className()) { oldObject, newObject in
            let pets = newObject!["pets"] as! List<MigrationObject>
            for dog in oldObject!["dogs"] as! List<DynamicObject> {
                let pet = migration.create(Pet.className(), value: [dog["name"], PetType.dog.rawValue])
                pets.append(pet)
            }
        }
        // We migrate over the old dog list to make sure all dogs get added, even those without
        // an owner.
        // Related issue: https://github.com/realm/realm-cocoa/issues/6734
        migration.enumerateObjects(ofType: "Dog") { oldDogObject, _ in
            var dogFound = false
            migration.enumerateObjects(ofType: Person.className()) { _, newObject in
                for pet in newObject!["pets"] as! List<DynamicObject> where pet["name"] as! String == oldDogObject!["name"] as! String {
                    dogFound = true
                    break
                }
            }
            if !dogFound {
                migration.create(Pet.className(), value: [oldDogObject!["name"], PetType.dog.rawValue])
            }
        }
        // The data cannot be deleted just yet since the table is target of cross-table link columns.
        // See https://github.com/realm/realm-cocoa/issues/3686
        // migration.deleteData(forType: PetType.dog)
    }
}

// MARK: - Example data

// Example data for this schema version.
let exampleData: (Realm) -> Void = { realm in
    let person1 = Person(fullName: "John Doe", age: 42)
    let person2 = Person(fullName: "Jane Doe", age: 43)
    let person3 = Person(fullName: "John Smith", age: 44)
    let pet1 = Pet(name: "Marley", type: .dog)
    let pet2 = Pet(name: "Lassie", type: .dog)
    let pet3 = Pet(name: "Toto", type: .dog)
    let pet4 = Pet(name: "Slinkey", type: .dog)
    realm.add([person1, person2, person3])
    person1.pets.append(pet1)
    person1.pets.append(pet2)
    person2.pets.append(pet3)
    // pet1, pet2 and pet3 get added automatically by adding them to a list.
    // pet4 has to be added manually though since it's not attached to a person yet.
    realm.add(pet4)
}

#endif