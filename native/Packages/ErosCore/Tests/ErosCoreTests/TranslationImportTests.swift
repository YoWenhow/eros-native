import Foundation
import XCTest
@testable import ErosCore

final class TranslationImportTests:XCTestCase {
    let license="署名-非商业性使用-相同方式共享 3.0 中国大陆"
    func data(name:String="英语",intro:String="",original:String="english") throws -> Data {
        try JSONSerialization.data(withJSONObject:["repo":"https://github.com/EhTagTranslation/Database","head":["sha":String(repeating:"a",count:40)],"version":7,"data":[["namespace":"language","count":1,"frontMatters":["copyright":"Original author"],"data":[original:["name":name,"intro":intro,"links":"https://unused.invalid"]]]]])
    }
    func manifest(_ data:Data) throws -> TranslationManifest {
        try TranslationManifest(version:"v7.1.0",hash:TranslationDigest.sha256(data),schemaVersion:7,byteCount:data.count,sourceURL:URL(string:"https://github.com/EhTagTranslation/Database/releases/download/v7.1.0/db.text.json")!)
    }
    func testDigestKnownVectors() {
        XCTAssertEqual(TranslationDigest.sha256(Data()),"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TranslationDigest.sha256(Data("abc".utf8)),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(TranslationDigest.sha256(Data(String(repeating:"a",count:1000000).utf8)),"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
    func testImportSanitizesMarkupPreservesAttributionAndKeys() throws {
        let bytes=try data(name:"<b>英语</b>",intro:"<script>bad()</script><img src='https://evil.invalid'><p>hello</p>")
        let result=try TranslationImporter.parse(bytes,manifest:manifest(bytes),license:license)
        XCTAssertEqual(result.entries.first?.localizedText,"英语"); XCTAssertEqual(result.entries.first?.description,"hello")
        XCTAssertEqual(result.entries.first?.key.original,"english");XCTAssertEqual(result.installation.attribution["language"],"Original author")
    }
    func testEmptyNameFallsBackAndPlainAnglesSurvive() throws {
        let bytes=try data(name:"<script>bad</script>",intro:"1 < 2 and 3 > 2")
        let result=try TranslationImporter.parse(bytes,manifest:manifest(bytes),license:license)
        XCTAssertEqual(result.entries.first?.localizedText,"english");XCTAssertEqual(result.entries.first?.description,"1 < 2 and 3 > 2")
    }
    func testDigestAndSizeMismatchRejectBeforeImport() throws {
        let a=try data(),b=try data(name:"法语")
        XCTAssertThrowsError(try TranslationImporter.parse(b,manifest:manifest(a),license:license))
        XCTAssertThrowsError(try TranslationImporter.parse(a+Data([32]),manifest:manifest(a),license:license))
        XCTAssertThrowsError(try TranslationImporter.parse(a,manifest:manifest(a),license:"unknown"))
    }
    func testDuplicateEscapedKeysAndNestedDuplicatesRejected() throws {
        for text in [#"{"a":1,"\u0061":2}"#,#"{"x":{"a":1,"a":2}}"#,#"[1,]"#,#"{"a":1,}"#,#"{"a":"bad\q"}"#] {
            XCTAssertThrowsError(try TranslationJSONValidation.validate(Data(text.utf8)),text)
        }
        try TranslationJSONValidation.validate(Data(#"{"a":[true,false,null,1e2,"x\"y"]}"#.utf8))
    }
    func testDeepOrOversizedJSONRejected() {
        XCTAssertThrowsError(try TranslationJSONValidation.validate(Data((String(repeating:"[",count:40)+"0"+String(repeating:"]",count:40)).utf8)))
        XCTAssertThrowsError(try TranslationJSONValidation.validate(Data(repeating:32,count:TranslationManifest.maximumByteCount+1)))
    }
    func testWrongSchemaUnknownNamespaceAndCountsRejected() throws {
        let bytes=try data();let text=String(decoding:bytes,as:UTF8.self)
        for changed in [text.replacingOccurrences(of:"\"version\":7",with:"\"version\":8"),text.replacingOccurrences(of:"language",with:"unknown"),text.replacingOccurrences(of:"\"count\":1",with:"\"count\":2")] {
            let d=Data(changed.utf8);XCTAssertThrowsError(try TranslationImporter.parse(d,manifest:manifest(d),license:license))
        }
    }
}
