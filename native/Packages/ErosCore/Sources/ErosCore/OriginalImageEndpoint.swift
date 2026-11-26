import Foundation

/// Both website forms are charge-capable entry points; neither may leak through a display client.
public enum OriginalImageEndpoint {
    public static func matchesPath(_ url: URL) -> Bool {
        url.path == "/fullimg.php" || url.path.hasPrefix("/fullimg/")
    }
    static func matchesGallery(_ url: URL, gallery: GalleryID) -> Bool {
        if url.path == "/fullimg.php" {
            guard let query=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems,
                  query.filter({$0.name=="gid"}).map(\.value)==[String(gallery.value)],
                  query.filter({$0.name=="page"}).count==1,
                  let page=query.first(where:{$0.name=="page"})?.value, digits(page),
                  Set(query.map(\.name)).count==query.count,
                  query.allSatisfy({["gid","page","key"].contains($0.name) && ($0.value?.count ?? 0)<=1024}) else{return false}
            return true
        }
        let parts=url.path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==6,parts[0].isEmpty,parts[1]=="fullimg",parts[2]==String(gallery.value),
              digits(String(parts[3])),!parts[4].isEmpty,parts[4].count<=1024,
              parts[4].allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="_" || $0=="-")}),
              !parts[5].isEmpty,parts[5] != ".",parts[5] != "..",url.query==nil else{return false}
        return true
    }
    private static func digits(_ value:String)->Bool {
        !value.isEmpty && value.utf8.allSatisfy({(48...57).contains($0)}) && Int(value) != nil
    }
}
