import Foundation
import XCTest
import ErosCore
import ErosNetworking

final class GalleryInteractionPolicyTests:XCTestCase {
    func testRatingAndTagsHaveSeparateOptInExactFieldsAndSite() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let ref=GalleryReference(key:GalleryKey(site:.ex,galleryID:try GalleryID(42)),token:try SensitiveText("synthetic")),request=try GalleryRequest(reference:ref,scope:scope)
        let html="<script>var api_url='https://s.exhentai.org/api.php';var apiuid=7;var apikey='SYNTHETIC';</script>"
        let response=try HTTPResponse(requestID:UUID(),scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data(html.utf8),finalURL:URL(string:"https://exhentai.org/g/42/synthetic/")!)
        let api=try CommentWriteParser().api(response,request:request),action=GalleryInteractionAction.rating(try RatingMutation(steps:9))
        XCTAssertThrowsError(try EndpointBuilder(policy:NetworkPolicy(allowGalleryAPI:true)).galleryInteraction(action,request:request,api:api))
        let policy=NetworkPolicy(allowGalleryInteractions:true),builder=EndpointBuilder(policy:policy)
        let post=try builder.galleryInteraction(action,request:request,api:api),object=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(post.body)) as? [String:Any])
        XCTAssertEqual(object["rating"] as? Int,9);XCTAssertEqual(object["method"] as? String,"rategallery");XCTAssertEqual(object.count,6)
        let tag=try builder.galleryInteraction(.tag(TagMutation(namespace:"artist",original:"Original Name",direction:1)),request:request,api:api)
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(tag.body)) as? [String:Any]);XCTAssertEqual(fields["tags"] as? String,"artist:Original Name");XCTAssertEqual(fields.count,7)
        XCTAssertThrowsError(try policy.validate(URL(string:"https://api.e-hentai.org/api.php")!,scope:scope))
        var wrong=object;wrong["extra"]="bad"
        XCTAssertThrowsError(try policy.validate(HTTPRequest(id:UUID(),scope:scope,url:api.endpoint,method:.post,headers:[:],body:JSONSerialization.data(withJSONObject:wrong))))
        wrong=object;wrong["method"]="geteditcomment"
        XCTAssertThrowsError(try policy.validate(HTTPRequest(id:UUID(),scope:scope,url:api.endpoint,method:.post,headers:[:],body:JSONSerialization.data(withJSONObject:wrong))))
        let reply=try HTTPResponse(requestID:post.id,scope:scope,status:200,headers:["Content-Type":"text/html"],body:Data("{}".utf8),finalURL:post.url)
        XCTAssertNoThrow(try ResponseClassifier(policy:policy).validate(reply,request:post,kind:.galleryInteractionJSON,now:Date()))
        XCTAssertThrowsError(try ResponseClassifier(policy:policy).validate(reply,request:post,kind:.json,now:Date()))
        XCTAssertThrowsError(try ResponseClassifier(policy:policy).validate(reply,request:post,kind:.galleryMutationJSON,now:Date()))
    }
    func testRawAPIRejectsInvalidRatingTypesAndMultipleTagPayloads() throws {
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:1)
        let policy=NetworkPolicy(allowGalleryInteractions:true),url=URL(string:"https://s.exhentai.org/api.php")!
        let base:[String:Any]=["apiuid":7,"apikey":"SYNTHETIC","gid":42,"token":"synthetic"]
        var cases:[[String:Any]]=[]
        for rating:Any in [true,0,11,"8"] { var item=base;item["method"]="rategallery";item["rating"]=rating;cases.append(item) }
        for tags in ["artist:a,group:b","artist:\"a$\"","temp:new tag"] { var item=base;item["method"]="taggallery";item["tags"]=tags;item["vote"]=1;cases.append(item) }
        for item in cases { XCTAssertThrowsError(try policy.validate(HTTPRequest(id:UUID(),scope:scope,url:url,method:.post,headers:[:],body:JSONSerialization.data(withJSONObject:item)))) }
    }

}
