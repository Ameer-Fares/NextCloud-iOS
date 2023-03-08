//
//  NCEndToEndMetadata.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 13/11/17.
//  Copyright © 2017 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import NextcloudKit
import Gzip

class NCEndToEndMetadata: NSObject {

    struct E2eeV1: Codable {

        struct Metadata: Codable {
            let metadataKeys: [String: String]
            let version: Int
        }

        struct Encrypted: Codable {
            let key: String
            let filename: String
            let mimetype: String
            let version: Int
        }

        struct Files: Codable {
            let initializationVector: String
            let authenticationTag: String?
            let metadataKey: Int
            let encrypted: String
        }

        struct Filedrop: Codable {
            let initializationVector: String
            let authenticationTag: String?
            let metadataKey: Int
            let encrypted: String
        }

        let metadata: Metadata
        let files: [String: Files]?
        let filedrop: [String: Filedrop]?
    }

    struct E2eeV2: Codable {

        struct Metadata: Codable {
            let authenticationTag: String
            let ciphertext: String
            let nonce: String
        }

        struct Users: Codable {
            let certificate: String
            let encryptedKey: String
            let userId: String
        }

        /*
        struct Encrypted: Codable {
            let key: String
            let filename: String
            let mimetype: String
            let version: Int
        }

        struct Files: Codable {
            let initializationVector: String
            let authenticationTag: String?
            let metadataKey: Int
            let encrypted: String
        }

        struct Filedrop: Codable {
            let initializationVector: String
            let authenticationTag: String?
            let metadataKey: Int
            let encrypted: String
        }
        */

        let version: Int
        let metadata: Metadata
        let users: [Users]?
        //let files: [String: Files]?
        //let filedrop: [String: Filedrop]?
    }

    // --------------------------------------------------------------------------------------------
    // MARK: Encode JSON Metadata V1
    // --------------------------------------------------------------------------------------------

    func encoderMetadata(_ items: [tableE2eEncryption], account: String, serverUrl: String) -> String? {

        let encoder = JSONEncoder()
        var metadataKeys: [String: String] = [:]
        let metadataVersion: Int = 1
        var files: [String: E2eeV1.Files] = [:]
        var filesCodable: [String: E2eeV1.Files]?
        var filedrop: [String: E2eeV1.Filedrop] = [:]
        var filedropCodable: [String: E2eeV1.Filedrop]?
        let privateKey = CCUtility.getEndToEndPrivateKey(account)

        for item in items {

            //
            // metadata
            //
            if let metadatakey = (item.metadataKey.data(using: .utf8)?.base64EncodedString()),
               let metadataKeyEncrypted = NCEndToEndEncryption.sharedManager().encryptAsymmetricString(metadatakey, publicKey: nil, privateKey: privateKey) {
                let metadataKeyEncryptedBase64 = metadataKeyEncrypted.base64EncodedString()
                metadataKeys["\(item.metadataKeyIndex)"] = metadataKeyEncryptedBase64
            }

            //
            // files
            //
            if item.blob == "files" {
                let encrypted = E2eeV1.Encrypted(key: item.key, filename: item.fileName, mimetype: item.mimeType, version: item.version)
                do {
                    // Create "encrypted"
                    let json = try encoder.encode(encrypted)
                    let encryptedString = String(data: json, encoding: .utf8)
                    if let encrypted = NCEndToEndEncryption.sharedManager().encryptEncryptedJson(encryptedString, key: item.metadataKey) {
                        let record = E2eeV1.Files(initializationVector: item.initializationVector, authenticationTag: item.authenticationTag, metadataKey: 0, encrypted: encrypted)
                        files.updateValue(record, forKey: item.fileNameIdentifier)
                    }
                } catch let error {
                    print("Serious internal error in encoding metadata (" + error.localizedDescription + ")")
                    return nil
                }
            }

            //
            // filedrop
            //
            if item.blob == "filedrop" {
                let encrypted = E2eeV1.Encrypted(key: item.key, filename: item.fileName, mimetype: item.mimeType, version: item.version)
                do {
                    // Create "encrypted"
                    let json = try encoder.encode(encrypted)
                    let encryptedString = (json.base64EncodedString())
                    if let encryptedData = NCEndToEndEncryption.sharedManager().encryptAsymmetricString(encryptedString, publicKey: nil, privateKey: privateKey) {
                        let encrypted = encryptedData.base64EncodedString()
                        let record = E2eeV1.Filedrop(initializationVector: item.initializationVector, authenticationTag: item.authenticationTag, metadataKey: 0, encrypted: encrypted)
                        filedrop.updateValue(record, forKey: item.fileNameIdentifier)
                    }
                } catch let error {
                    print("Serious internal error in encoding metadata (" + error.localizedDescription + ")")
                    return nil
                }
            }
        }

        // Create Json
        let metadata = E2eeV1.Metadata(metadataKeys: metadataKeys, version: metadataVersion)
        if !files.isEmpty { filesCodable = files }
        if !filedrop.isEmpty { filedropCodable = filedrop }
        let e2ee = E2eeV1(metadata: metadata, files: filesCodable, filedrop: filedropCodable)
        do {
            let data = try encoder.encode(e2ee)
            data.printJson()
            let jsonString = String(data: data, encoding: .utf8)
            return jsonString
        } catch let error {
            print("Serious internal error in encoding e2ee (" + error.localizedDescription + ")")
            return nil
        }
    }

    // --------------------------------------------------------------------------------------------
    // MARK: Decode JSON Metadata Bridge
    // --------------------------------------------------------------------------------------------

    func decoderMetadata(_ json: String, serverUrl: String, account: String, urlBase: String, userId: String, ownerId: String?) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }

        let decoder = JSONDecoder()

        if (try? decoder.decode(E2eeV1.self, from: data)) != nil {
            return decoderMetadataV1(json, serverUrl: serverUrl, account: account, urlBase: urlBase, userId: userId)
        } else if (try? decoder.decode(E2eeV2.self, from: data)) != nil {
            return decoderMetadataV2(json, serverUrl: serverUrl, account: account, urlBase: urlBase, userId: userId, ownerId: ownerId)
        } else {
            return false
        }
    }

    // --------------------------------------------------------------------------------------------
    // MARK: Decode JSON Metadata V1
    // --------------------------------------------------------------------------------------------

    func decoderMetadataV1(_ json: String, serverUrl: String, account: String, urlBase: String, userId: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }

        let decoder = JSONDecoder()
        let privateKey = CCUtility.getEndToEndPrivateKey(account)

        do {
            data.printJson()
            let json = try decoder.decode(E2eeV1.self, from: data)

            let metadata = json.metadata
            let files = json.files
            let filedrop = json.filedrop
            var metadataKeys: [String: String] = [:]
            let metadataVersion: Int = metadata.version

            //
            // metadata
            //
            for metadataKey in metadata.metadataKeys {
                if let metadataKeyData: NSData = NSData(base64Encoded: metadataKey.value, options: NSData.Base64DecodingOptions(rawValue: 0)),
                   let metadataKeyBase64 = NCEndToEndEncryption.sharedManager().decryptAsymmetricData(metadataKeyData as Data?, privateKey: privateKey),
                   let metadataKeyBase64Data = Data(base64Encoded: metadataKeyBase64, options: NSData.Base64DecodingOptions(rawValue: 0)),
                   let key = String(data: metadataKeyBase64Data, encoding: .utf8) {
                    metadataKeys[metadataKey.key] = key
                }
            }

            //
            // files
            //
            if let files = files {
                for files in files {
                    let fileNameIdentifier = files.key
                    let files = files.value as E2eeV1.Files

                    let encrypted = files.encrypted
                    let authenticationTag = files.authenticationTag
                    guard let metadataKey = metadataKeys["\(files.metadataKey)"] else { continue }
                    let metadataKeyIndex = files.metadataKey
                    let initializationVector = files.initializationVector

                    if let encrypted = NCEndToEndEncryption.sharedManager().decryptEncryptedJson(encrypted, key: metadataKey),
                       let encryptedData = encrypted.data(using: .utf8) {
                        do {
                            let encrypted = try decoder.decode(E2eeV1.Encrypted.self, from: encryptedData)

                            if let metadata = NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "account == %@ AND fileName == %@", account, fileNameIdentifier)) {

                                let object = tableE2eEncryption()

                                object.account = account
                                object.authenticationTag = authenticationTag ?? ""
                                object.blob = "files"
                                object.fileName = encrypted.filename
                                object.fileNameIdentifier = fileNameIdentifier
                                object.fileNamePath = CCUtility.returnFileNamePath(fromFileName: encrypted.filename, serverUrl: serverUrl, urlBase: urlBase, userId: userId, account: account)
                                object.key = encrypted.key
                                object.initializationVector = initializationVector
                                object.metadataKey = metadataKey
                                object.metadataKeyIndex = metadataKeyIndex
                                object.metadataVersion = metadataVersion
                                object.mimeType = encrypted.mimetype
                                object.serverUrl = serverUrl
                                object.version = encrypted.version

                                // If exists remove records
                                NCManageDatabase.shared.deleteE2eEncryption(predicate: NSPredicate(format: "account == %@ AND fileNamePath == %@", object.account, object.fileNamePath))
                                NCManageDatabase.shared.deleteE2eEncryption(predicate: NSPredicate(format: "account == %@ AND fileNameIdentifier == %@", object.account, object.fileNameIdentifier))

                                // Write file parameter for decrypted on DB
                                NCManageDatabase.shared.addE2eEncryption(object)

                                // Update metadata on tableMetadata
                                metadata.fileNameView = encrypted.filename

                                let results = NextcloudKit.shared.nkCommonInstance.getInternalType(fileName: encrypted.filename, mimeType: metadata.contentType, directory: metadata.directory)

                                metadata.contentType = results.mimeType
                                metadata.iconName = results.iconName
                                metadata.classFile = results.classFile

                                NCManageDatabase.shared.addMetadata(metadata)
                            }

                        } catch let error {
                            print("Serious internal error in decoding files (" + error.localizedDescription + ")")
                            return false
                        }
                    }
                }
            }

            //
            // filedrop
            //
            if let filedrop = filedrop {
                for filedrop in filedrop {
                    let fileNameIdentifier = filedrop.key
                    let filedrop = filedrop.value as E2eeV1.Filedrop

                    let encrypted = filedrop.encrypted
                    let authenticationTag = filedrop.authenticationTag
                    guard let metadataKey = metadataKeys["\(filedrop.metadataKey)"] else { continue }
                    let metadataKeyIndex = filedrop.metadataKey
                    let initializationVector = filedrop.initializationVector

                    if let encryptedData = NSData(base64Encoded: encrypted, options: NSData.Base64DecodingOptions(rawValue: 0)),
                       let encryptedBase64 = NCEndToEndEncryption.sharedManager().decryptAsymmetricData(encryptedData as Data?, privateKey: privateKey),
                       let encryptedBase64Data = Data(base64Encoded: encryptedBase64, options: NSData.Base64DecodingOptions(rawValue: 0)),
                       let encrypted = String(data: encryptedBase64Data, encoding: .utf8),
                       let encryptedData = encrypted.data(using: .utf8) {

                        do {
                            let encrypted = try decoder.decode(E2eeV1.Encrypted.self, from: encryptedData)

                            if let metadata = NCManageDatabase.shared.getMetadata(predicate: NSPredicate(format: "account == %@ AND fileName == %@", account, fileNameIdentifier)) {

                                let object = tableE2eEncryption()

                                object.account = account
                                object.authenticationTag = authenticationTag ?? ""
                                object.blob = "filedrop"
                                object.fileName = encrypted.filename
                                object.fileNameIdentifier = fileNameIdentifier
                                object.fileNamePath = CCUtility.returnFileNamePath(fromFileName: encrypted.filename, serverUrl: serverUrl, urlBase: urlBase, userId: userId, account: account)
                                object.key = encrypted.key
                                object.initializationVector = initializationVector
                                object.metadataKey = metadataKey
                                object.metadataKeyIndex = metadataKeyIndex
                                object.metadataVersion = metadataVersion
                                object.mimeType = encrypted.mimetype
                                object.serverUrl = serverUrl
                                object.version = encrypted.version

                                // If exists remove records
                                NCManageDatabase.shared.deleteE2eEncryption(predicate: NSPredicate(format: "account == %@ AND fileNamePath == %@", object.account, object.fileNamePath))
                                NCManageDatabase.shared.deleteE2eEncryption(predicate: NSPredicate(format: "account == %@ AND fileNameIdentifier == %@", object.account, object.fileNameIdentifier))

                                // Write file parameter for decrypted on DB
                                NCManageDatabase.shared.addE2eEncryption(object)

                                // Update metadata on tableMetadata
                                metadata.fileNameView = encrypted.filename

                                let results = NextcloudKit.shared.nkCommonInstance.getInternalType(fileName: encrypted.filename, mimeType: metadata.contentType, directory: metadata.directory)

                                metadata.contentType = results.mimeType
                                metadata.iconName = results.iconName
                                metadata.classFile = results.classFile

                                NCManageDatabase.shared.addMetadata(metadata)
                            }

                        } catch let error {
                            print("Serious internal error in decoding filedrop (" + error.localizedDescription + ")")
                            return false
                        }
                    }
                }
            }

        } catch let error {
            print("Serious internal error in decoding metadata (" + error.localizedDescription + ")")
            return false
        }

        return true
    }

    // --------------------------------------------------------------------------------------------
    // MARK: Decode JSON Metadata V2
    // --------------------------------------------------------------------------------------------

    func decoderMetadataV2(_ json: String, serverUrl: String, account: String, urlBase: String, userId: String, ownerId: String?) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }

        let decoder = JSONDecoder()
        let privateKey = CCUtility.getEndToEndPrivateKey(account)
        let passphrase = CCUtility.getEndToEndPassphrase(account)

        do {
            data.printJson()
            let json = try decoder.decode(E2eeV2.self, from: data)

            let metadata = json.metadata
            let version = json.version
            let users = json.users

            // Check version 2
            if version != 2 { return false }

            if let users = users {
                for user in users {
                    if user.userId == ownerId, let keyData = Data(base64Encoded: user.encryptedKey) {
                        let key = String(data: keyData as Data, encoding: .utf8)
                        let privateKey = NCEndToEndEncryption.sharedManager().decryptPrivateKey(user.encryptedKey, passphrase: passphrase, publicKey: user.certificate)
                        print("OK")
                        // let key = NCEndToEndEncryption.sharedManager().decryptAsymmetricData(keyData as Data?, privateKey: privateKey)
                        // let ciphertext = metadata.ciphertext
                        // let encrypted = NCEndToEndEncryption.sharedManager().decryptEncryptedJson(ciphertext, key: key)
                    }
                }
            }


        } catch let error {
            print("Serious internal error in decoding metadata (" + error.localizedDescription + ")")
            return false
        }

        return true
    }
}
