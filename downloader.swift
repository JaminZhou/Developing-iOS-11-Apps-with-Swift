import Foundation
import SystemConfiguration

class Reachability {
    class func isConnectedToNetwork() -> Bool {
        guard let flags = getFlags() else {return false}
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return (isReachable && !needsConnection)
    }
    
    class func getFlags() -> SCNetworkReachabilityFlags? {
        guard let reachability = ipv4Reachability() ?? ipv6Reachability() else {return nil}
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {return nil}
        return flags
    }
    
    class func ipv6Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in6()
        zeroAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin6_family = sa_family_t(AF_INET6)
        
        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }
    
    class func ipv4Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)
        
        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }
}

class DownloadSessionManager : NSObject, URLSessionDownloadDelegate {
    
    static let shared = DownloadSessionManager()
    var filePath : String?
    var url: URL?
    var resumeData: Data?
    
    let semaphore = DispatchSemaphore.init(value: 0)
    var session : URLSession!
    
    override init() {
        super.init()
        self.resetSession()
    }
    
    func resetSession() {
        self.session = URLSession(configuration: URLSessionConfiguration.default, delegate: self, delegateQueue: nil)
    }
    
    func downloadFile(fromURL url: URL, toPath path: String) {
        self.filePath = path
        self.url = url
        self.resumeData = nil
        taskStartedAt = Date()
        let task = session.downloadTask(with: url)
        task.resume()
        semaphore.wait()
    }
    
    func resumeDownload() {
        self.resetSession()
        
        if let resumeData = self.resumeData {
            print("resuming file download...")
            let task = session.downloadTask(withResumeData: resumeData)
            task.resume()
            self.resumeData = nil
            semaphore.wait()
        } else {
            print("retrying file download...")
            self.downloadFile(fromURL: self.url!, toPath: self.filePath!)
        }
    }
    
    func show(progress: Int, barWidth: Int, speedInK: Int) {
        print("\r[", terminator: "")
        let pos = Int(Double(barWidth*progress)/100.0)
        for i in 0...barWidth {
            switch(i) {
            case _ where i < pos:
                print("🁢", terminator:"")
                break
            case pos:
                print("🁢", terminator:"")
                break
            default:
                print(" ", terminator:"")
                break
            }
        }
        
        print("] \(progress)% \(speedInK)KB/s", terminator:"")
        fflush(__stdoutp)
    }
    
    var taskStartedAt : Date?
    //MARK : URLSessionDownloadDelegate
    func urlSession(_: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let timeDownloaded = now.timeIntervalSince(taskStartedAt!)
        let kbs = Int( floor( Float(totalBytesWritten) / 1024.0 / Float(timeDownloaded) ) )
        show(progress: Int(Double(totalBytesWritten)/Double(totalBytesExpectedToWrite)*100.0), barWidth: 70, speedInK: kbs)
    }
    
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer {
            semaphore.signal()
        }
        
        print("")
        
        guard let _ = self.filePath else {
            print("No destination path to copy the downloaded file at \(location)")
            return
        }
        
        print("moving \(location) to \(self.filePath!)")
        
        do {
            try FileManager.default.moveItem(at: location, to: URL.init(fileURLWithPath: "\(filePath!)"))
        }
            
        catch let error {
            print("Ooops! Something went wrong: \(error)")
        }
    }
    
    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else {return}
        
        defer {
            defer {
                semaphore.signal()
            }
            
            if !Reachability.isConnectedToNetwork() {
                print("Waiting for connection to be restored")
                repeat {
                    sleep(1)
                } while !Reachability.isConnectedToNetwork()
            }
            
            self.resumeDownload()
        }
        
        print("")
        
        print("Ooops! Something went wrong: \(error.localizedDescription)")
        
        guard let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data else {
            return
        }
        
        self.resumeData = resumeData
    }
}

class iTunesUController {
    
    class func getVideoResourceURLs(fromHTML: String) -> ([String]) {
        var list = [String]()
        list.append(contentsOf: getResourceURLs(fromHTML: fromHTML, fileExtension: "m4v"))
        list.append(contentsOf: getResourceURLs(fromHTML: fromHTML, fileExtension: "mp4"))
        return list
    }
    
    class func getResourceURLs(fromHTML: String, fileExtension: String)  -> ([String]) {
        let pat = "\\b.*(https://.*\\." + fileExtension + ")\\b"
        let regex = try! NSRegularExpression(pattern: pat, options: [])
        let matches = regex.matches(in: fromHTML, options: [], range: NSRange(location: 0, length: fromHTML.count))
        var resourceURLs = [String]()
        for match in matches {
            let range = match.range(at:1)
            let r = fromHTML.index(fromHTML.startIndex, offsetBy: range.location) ..< fromHTML.index(fromHTML.startIndex, offsetBy: range.location+range.length)
            let url = fromHTML[r]
            resourceURLs.append(String(url))
        }
        
        return resourceURLs
    }
    
    class func getStringContent(fromURL: String) -> (String) {
        let session = URLSession(configuration: URLSessionConfiguration.default, delegate: nil, delegateQueue: nil)
        var result = ""
        guard let URL = URL(string: fromURL) else {return result}
        var request = URLRequest(url: URL)
        request.httpMethod = "GET"
        
        let semaphore = DispatchSemaphore.init(value: 0)
        let task = session.dataTask(with: request, completionHandler: { (data: Data?, response: URLResponse?, error: Error?) -> Void in
            if (error == nil) {
                result = String.init(data: data!, encoding: .ascii)!
            } else {
                print("URL Session Task Failed: %@", error!.localizedDescription);
            }
            
            semaphore.signal()
        })
        task.resume()
        semaphore.wait()
        return result
    }
    
    class func downloadFile(urlString: String) {
        let fileName = URL(fileURLWithPath: urlString).lastPathComponent
        
        guard !FileManager.default.fileExists(atPath: "./" + fileName) else {
            print("\(fileName): already exists, nothing to do!")
            return
        }
        
        print("Getting \(fileName) (\(urlString)):")
        
        guard let url = URL(string: urlString) else {
            print("<\(urlString)> is not valid URL!")
            return
        }
        
        DownloadSessionManager.shared.downloadFile(fromURL: url, toPath: "\(fileName)")
    }
}

let htmlText = iTunesUController.getStringContent(fromURL: "https://itunes.apple.com/cn/course/developing-ios-11-apps-with-swift/id1309275316")
let resourceURLs = iTunesUController.getVideoResourceURLs(fromHTML: htmlText)
for url in resourceURLs {
    iTunesUController.downloadFile(urlString: url)
}
