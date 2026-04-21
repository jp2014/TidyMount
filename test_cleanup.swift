import Foundation

func test() {
    let volumeName = "12TB"
    let names = ["12TB", "12TB-1", "12TB-2", "12TB-4", "12TB-foo", "2TB-1", "Macintosh HD"]
    
    let matches = names.filter { name in
        if name == volumeName { return true }
        if name.hasPrefix("\(volumeName)-") {
            let suffix = name.replacingOccurrences(of: "\(volumeName)-", with: "")
            return Int(suffix) != nil
        }
        return false
    }
    print(matches)
}

test()
