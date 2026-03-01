//
//  IPATool.swift
//  MuffinStoreJailed
//
//  Created by Mineek on 19/10/2024.
//

// Heavily inspired by ipatool-py.
// https://github.com/NyaMisty/ipatool-py

import Foundation
import CommonCrypto
import Zip

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}

class SHA1 {
    static func hash(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }
}

extension String {
    subscript (i: Int) -> String {
        return String(self[index(startIndex, offsetBy: i)])
    }

    subscript (r: Range<Int>) -> String {
        let start = index(startIndex, offsetBy: r.lowerBound)
        let end = index(startIndex, offsetBy: r.upperBound)
        return String(self[start..<end])
    }
}

class StoreClient {
    var session: URLSession
    var appleId: String
    var password: String
    var guid: String?
    var accountName: String?
    var authHeaders: [String: String]?
    var authCookies: [HTTPCookie]?
    var pod: String?

    init(appleId: String, password: String) {
        session = URLSession.shared
        self.appleId = appleId
        self.password = password
        self.guid = nil
        self.accountName = nil
        self.authHeaders = nil
        self.authCookies = nil
        self.pod = nil
    }

    func generateGuid(appleId: String) -> String {
        print("Generating GUID")
        let DEFAULT_GUID = "000C2941396B"
        let GUID_DEFAULT_PREFIX = 2
        let GUID_SEED = "CAFEBABE"
        let GUID_POS = 10

        let h = SHA1.hash((GUID_SEED + appleId + GUID_SEED).data(using: .utf8)!).hexString
        let defaultPart = DEFAULT_GUID.prefix(GUID_DEFAULT_PREFIX)
        let hashPart = h[GUID_POS..<GUID_POS + (DEFAULT_GUID.count - GUID_DEFAULT_PREFIX)]
        let guid = (defaultPart + hashPart).uppercased()

        print("Came up with GUID: \(guid)")
        return guid
    }

    func saveAuthInfo() -> Void {
        var authCookiesEnc1 = NSKeyedArchiver.archivedData(withRootObject: authCookies!)
        var authCookiesEnc = authCookiesEnc1.base64EncodedString()
        var out: [String: Any] = [
            "appleId": appleId,
            "password": password,
            "guid": guid,
            "accountName": accountName,
            "authHeaders": authHeaders,
            "authCookies": authCookiesEnc,
            "pod": pod
        ]
        var data = try! JSONSerialization.data(withJSONObject: out, options: [])
        var base64 = data.base64EncodedString()
        EncryptedKeychainWrapper.saveAuthInfo(base64: base64)
    }

    func tryLoadAuthInfo() -> Bool {
        if let base64 = EncryptedKeychainWrapper.loadAuthInfo() {
            var data = Data(base64Encoded: base64)!
            var out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            appleId = out["appleId"] as! String
            password = out["password"] as! String
            guid = out["guid"] as? String
            accountName = out["accountName"] as? String
            authHeaders = out["authHeaders"] as? [String: String]
            var authCookiesEnc = out["authCookies"] as! String
            var authCookiesEnc1 = Data(base64Encoded: authCookiesEnc)!
            authCookies = NSKeyedUnarchiver.unarchiveObject(with: authCookiesEnc1) as? [HTTPCookie]
            pod = out["pod"] as? String
            print("Loaded auth info")
            return true
        }
        print("No auth info found, need to authenticate")
        return false
    }
    
    // pancakestore is saved! thanks ipatool!
    // admittedly i kinda owe this hoorah to that vibecoded ass pull-request, i had to stoop to its level too :(
    // oh well. - skadz, 2.24.26
    func getBagEndpoint() async -> String {
        let fallback = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate" // this is the old broken one, i'm just gonna have it as a fallback in case this amazingness somehow fails one day
        
        if guid == nil {
            guid = generateGuid(appleId: appleId)
        }
        guard let guid = guid else { return fallback }

        var request = URLRequest(url: URL(string: "https://init.itunes.apple.com/bag.xml?guid=\(guid)")!)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !data.isEmpty else { return fallback }

            // i'm sorry i'm sorry please don't hit me i know i know
            if let xmlString = String(data: data, encoding: .utf8),
               let plistStart = xmlString.range(of: "<plist"),
               let plistEnd = xmlString.range(of: "</plist>") {
                let plistSection = String(xmlString[plistStart.lowerBound..<plistEnd.upperBound])
                if let cleanData = plistSection.data(using: .utf8),
                   let plist = try PropertyListSerialization.propertyList(from: cleanData, options: [], format: nil) as? [String: Any],
                   let urlBag = plist["urlBag"] as? [String: Any],
                   let endpoint = urlBag["authenticateAccount"] as? String {
                    return endpoint
                }
            }
        } catch {
            print("failed to get bag endpoint!! \(error)")
        }

        return fallback
    }

    func authenticate(requestCode: Bool = false) -> Bool {
        if self.guid == nil {
            self.guid = generateGuid(appleId: appleId)
        }

        var req = [
            "appleId": appleId,
            "password": password,
            "guid": guid!,
            "rmp": "0",
            "why": "signIn"
        ]
        Task {
            let authURL = await getBagEndpoint()
            
            let url = URL(string: authURL)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = [
                "Accept": "*/*",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
            ]
            
            var ret = false
            
            for attempt in 1...4 {
                req["attempt"] = String(attempt)
                request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])
                let datatask = session.dataTask(with: request) { (data, response, error) in
                    if let error = error {
                        print("error 1 \(error.localizedDescription)")
                        return
                    }
                    if let response = response {
                        //                    print("Response: \(response)")
                        if let response = response as? HTTPURLResponse {
                            print("New URL: \(response.url!)")
                            request.url = response.url
                            
                            if let pod = response.value(forHTTPHeaderField: "pod") {
                                print("pod gotten: \(pod)")
                                self.pod = pod
                            }
                        }
                    }
                    if let data = data {
                        do {
                            let resp = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                            if let dsPersonId = resp["dsPersonId"] as? String, let passwordToken = resp["passwordToken"] as? String, !dsPersonId.isEmpty, !passwordToken.isEmpty {
                                print("Authentication successful")
                                var download_queue_info = resp["download-queue-info"] as! [String: Any]
                                var dsid = download_queue_info["dsid"] as! Int
                                var httpResp = response as! HTTPURLResponse
                                var storeFront = httpResp.value(forHTTPHeaderField: "x-set-apple-store-front")
                                print("Store front: \(storeFront!)")
                                self.authHeaders = [
                                    "X-Dsid": String(dsid),
                                    "iCloud-Dsid": String(dsid),
                                    "X-Apple-Store-Front": storeFront!,
                                    "X-Token": resp["passwordToken"] as! String
                                ]
                                self.authCookies = self.session.configuration.httpCookieStorage?.cookies
                                var accountInfo = resp["accountInfo"] as! [String: Any]
                                var address = accountInfo["address"] as! [String: String]
                                self.accountName = address["firstName"]! + " " + address["lastName"]!
                                self.saveAuthInfo()
                                ret = true
                            } else {
                                print("Authentication failed: \(resp["customerMessage"] as! String)")
                            }
                        } catch {
                            print("Error: \(error)")
                        }
                    }
                }
                datatask.resume()
                while datatask.state != .completed {
                    sleep(1)
                }
                if ret {
                    break
                }
                if requestCode {
                    ret = false
                    break
                }
            }
            return ret
        }
        return false
    }

    func volumeStoreDownloadProduct(appId: String, appVerId: String = "") -> [String: Any] {
        var req = [
            "creditDisplay": "",
            "guid": self.guid!,
            "salableAdamId": appId,
        ]
        if appVerId != "" {
            req["externalVersionId"] = appVerId
        }
        let url = URL(string: "https://p\(pod!)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=\(self.guid!)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
        ]
        request.httpBody = try! JSONSerialization.data(withJSONObject: req, options: [])
        print("Setting headers")
        for (key, value) in self.authHeaders! {
            print("Setting header \(key): \(value)")
            request.addValue(value, forHTTPHeaderField: key)
        }
        print("Setting cookies")
        self.session.configuration.httpCookieStorage?.setCookies(self.authCookies!, for: url, mainDocumentURL: nil)

        var resp = [String: Any]()
        let datatask = session.dataTask(with: request) { (data, response, error) in
            if let error = error {
                print("error 2 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    print("Got response")
                    let resp1 = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
                    if resp1["cancel-purchase-batch"] != nil {
                        print("Failed to download product: \(resp1["customerMessage"] as! String)")
                    }
                    resp = resp1
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Got download response")
        return resp
    }

    func download(appId: String, appVer: String = "", isRedownload: Bool = false) -> [String: Any] {
        return self.volumeStoreDownloadProduct(appId: appId, appVerId: appVer)
    }

    func downloadToPath(url: String, path: String) -> Void {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        let datatask = session.dataTask(with: req) { (data, response, error) in
            if let error = error {
                print("error 3 \(error.localizedDescription)")
                return
            }
            if let data = data {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                } catch {
                    print("Error: \(error)")
                }
            }
        }
        datatask.resume()
        while datatask.state != .completed {
            sleep(1)
        }
        print("Downloaded to \(path)")
    }
}

class IPATool {
    var session: URLSession
    var appleId: String
    var password: String
    var storeClient: StoreClient

    init(appleId: String, password: String) {
        print("init!")
        session = URLSession.shared
        self.appleId = appleId
        self.password = password
        storeClient = StoreClient(appleId: appleId, password: password)
    }

    func authenticate(requestCode: Bool = false) -> Bool {
        print("Authenticating to iTunes Store...")
        if !storeClient.tryLoadAuthInfo() {
            return storeClient.authenticate(requestCode: requestCode)
        } else {
            return true
        }
    }

    func getVersionIDList(appId: String) -> [String] {
        print("Retrieving download info for appId \(appId)")
        let downResp = storeClient.download(appId: appId, isRedownload: true)
        guard let songList = downResp["songList"] as? [[String: Any]], !songList.isEmpty else {
            print("Failed to get app download info!")
            return []
        }
        let downInfo = songList[0]
        guard let metadata = downInfo["metadata"] as? [String: Any],
              let appVerIds = metadata["softwareVersionExternalIdentifiers"] as? [Int] else {
            print("Failed to parse app version identifiers")
            return []
        }
        print("Got available version ids \(appVerIds)")
        return appVerIds.map { String($0) }
    }

    func downloadIPAForVersion(appId: String, appVerId: String) -> String {
        print("Downloading IPA for app \(appId) version \(appVerId)")
        let downResp = storeClient.download(appId: appId, appVer: appVerId)
        guard let songList = downResp["songList"] as? [[String: Any]], !songList.isEmpty else {
            print("Failed to get app download info!")
            return ""
        }
        let downInfo = songList[0]
        guard let url = downInfo["URL"] as? String else {
            print("Download URL missing in response")
            return ""
        }
        print("Got download URL: \(url)")
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let path = tempDir.appendingPathComponent("app.ipa").path
        if fm.fileExists(atPath: path) {
            print("Removing existing file at \(path)")
            do {
                try fm.removeItem(atPath: path)
            } catch {
                print("Failed to remove existing IPA: \(error)")
                return ""
            }
        }
        storeClient.downloadToPath(url: url, path: path)
        Zip.addCustomFileExtension("ipa")
        sleep(3)
        let path3 = URL(fileURLWithPath: path)
        let fileExtension = path3.pathExtension
        let fileName = path3.lastPathComponent
        let directoryName = fileName.replacingOccurrences(of: ".\(fileExtension)", with: "")
        let documentsUrl = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationUrl = documentsUrl.appendingPathComponent(directoryName, isDirectory: true)
        if fm.fileExists(atPath: destinationUrl.path) {
            print("Removing existing folder at \(destinationUrl.path)")
            do {
                try fm.removeItem(at: destinationUrl)
            } catch {
                print("Failed to remove existing extraction folder: \(error)")
                return ""
            }
        }
        
        let unzipDirectory: URL
        do {
            unzipDirectory = try Zip.quickUnzipFile(URL(fileURLWithPath: path))
        } catch {
            print("Failed to unzip IPA: \(error)")
            return ""
        }
        guard var metadata = downInfo["metadata"] as? [String: Any] else {
            print("Download metadata missing")
            return ""
        }
        let metadataPath = unzipDirectory.appendingPathComponent("iTunesMetadata.plist").path
        metadata["apple-id"] = appleId
        metadata["userName"] = appleId
        if !(metadata as NSDictionary).write(toFile: metadataPath, atomically: true) {
            print("Failed to write iTunesMetadata.plist")
            return ""
        }
        print("Wrote iTunesMetadata.plist")
        var appContentDir = ""
        let payloadDir = unzipDirectory.appendingPathComponent("Payload")
        for entry in try! fm.contentsOfDirectory(atPath: payloadDir.path) {
            if entry.hasSuffix(".app") {
                print("Found app content dir: \(entry)")
                appContentDir = "Payload/" + entry
                break
            }
        }
        print("Found app content dir: \(appContentDir)")
        guard let sinfsDict = downInfo["sinfs"] as? [[String: Any]], !sinfsDict.isEmpty else {
            print("SINF payload missing in download response")
            return ""
        }

        let manifestPath = unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("SC_Info").appendingPathComponent("Manifest.plist")
        if let scManifestData = try? Data(contentsOf: manifestPath),
           let scManifest = try? PropertyListSerialization.propertyList(from: scManifestData, options: [], format: nil) as? [String: Any],
           let sinfPaths = scManifest["SinfPaths"] as? [String] {
            for (i, sinfPath) in sinfPaths.enumerated() {
                guard i < sinfsDict.count, let sinfData = sinfsDict[i]["sinf"] as? Data else {
                    print("Invalid SINF data for index \(i)")
                    return ""
                }
                do {
                    try sinfData.write(to: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent(sinfPath))
                } catch {
                    print("Failed writing SINF path \(sinfPath): \(error)")
                    return ""
                }
                print("Wrote sinf to \(sinfPath)")
            }
        } else {
            print("Manifest.plist does not exist! Assuming it is an old app without one...")
            guard let infoListData = try? Data(contentsOf: unzipDirectory.appendingPathComponent(appContentDir).appendingPathComponent("Info.plist")),
                  let infoList = try? PropertyListSerialization.propertyList(from: infoListData, options: [], format: nil) as? [String: Any],
                  let executable = infoList["CFBundleExecutable"] as? String,
                  let sinfData = sinfsDict[0]["sinf"] as? Data else {
                print("Failed to derive fallback SINF path")
                return ""
            }
            let sinfPath = appContentDir + "/SC_Info/" + executable + ".sinf"
            do {
                try sinfData.write(to: unzipDirectory.appendingPathComponent(sinfPath))
            } catch {
                print("Failed writing fallback SINF: \(error)")
                return ""
            }
            print("Wrote sinf to \(sinfPath)")
        }
        print("Downloaded IPA to \(unzipDirectory.path)")
        return unzipDirectory.path
    }
}

class EncryptedKeychainWrapper {
    static func hasKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "dev.mineek.muffinstorejailed.key"
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func generateAndStoreKey() -> Void {
        self.deleteKey()
        print("Generating key")
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: "dev.mineek.muffinstorejailed.key",
                kSecAttrAccessControl as String: SecAccessControlCreateWithFlags(
                    kCFAllocatorDefault,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    [.privateKeyUsage, .biometryAny],
                    nil
                )!
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(query as CFDictionary, &error) else {
            print("Failed to generate key!!")
            return
        }
        print("Generated key!")
        print("Getting public key")
        let pubKey = SecKeyCopyPublicKey(privateKey)!
        print("Got public key")
        let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &error)! as Data
        let pubKeyBase64 = pubKeyData.base64EncodedString()
        print("Public key: \(pubKeyBase64)")
    }

    static func deleteKey() -> Void {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "dev.mineek.muffinstorejailed.key"
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveAuthInfo(base64: String) -> Void {
        if !hasKey() {
            generateAndStoreKey()
        }

        let fm = FileManager.default
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "dev.mineek.muffinstorejailed.key",
            kSecReturnRef as String: true
        ]
        var keyRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &keyRef)
        if status != errSecSuccess {
            print("Failed to get key!")
            return
        }
        print("Got key!")
        let key = keyRef as! SecKey
        print("Getting public key")
        let pubKey = SecKeyCopyPublicKey(key)!
        print("Got public key")
        print("Encrypting data")
        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(pubKey, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, base64.data(using: .utf8)! as CFData, &error) else {
            print("Failed to encrypt data!")
            return
        }
        print("Encrypted data")
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        fm.createFile(atPath: path, contents: encryptedData as Data, attributes: nil)
        print("Saved encrypted auth info")
    }

    static func loadAuthInfo() -> String? {
        let fm = FileManager.default
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if !fm.fileExists(atPath: path) {
            return nil
        }
        let data = fm.contents(atPath: path)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "dev.mineek.muffinstorejailed.key",
            kSecReturnRef as String: true
        ]
        var keyRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &keyRef)
        if status != errSecSuccess {
            print("Failed to get key!")
            return nil
        }
        print("Got key!")
        let key = keyRef as! SecKey
        let privKey = key
        print("Decrypting data")
        var error: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(privKey, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, data as CFData, &error) else {
            print("Failed to decrypt data!")
            return nil
        }
        print("Decrypted data")
        return String(data: decryptedData as Data, encoding: .utf8)
    }

    static func deleteAuthInfo() -> Void {
        let fm = FileManager.default
        let path = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("authinfo").path
        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
    }

    static func hasAuthInfo() -> Bool {
        return loadAuthInfo() != nil
    }

    static func getAuthInfo() -> [String: Any]? {
        if let base64 = loadAuthInfo() {
            var data = Data(base64Encoded: base64)!
            var out = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            return out
        }
        return nil
    }

    static func nuke() -> Void {
        deleteAuthInfo()
        deleteKey()
    }
}
