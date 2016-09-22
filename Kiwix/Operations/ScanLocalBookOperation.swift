//
//  ScanLocalBookOperation.swift
//  Kiwix
//
//  Created by Chris Li on 7/11/16.
//  Copyright © 2016 Chris. All rights reserved.
//

import CoreData
import Operations

class ScanLocalBookOperation: Operation {
    private let context: NSManagedObjectContext
    private(set) var firstBookAdded = false
    
    private var lastZimFileURLSnapshot: Set<NSURL>
    private(set) var currentZimFileURLSnapshot = Set<NSURL>()
    private let lastIndexFolderURLSnapshot: Set<NSURL>
    private(set) var currentIndexFolderURLSnapshot = Set<NSURL>()
    
    private let time = NSDate()
    
    init(lastZimFileURLSnapshot: Set<NSURL>, lastIndexFolderURLSnapshot: Set<NSURL>) {
        self.context = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        context.parentContext = NSManagedObjectContext.mainQueueContext
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        self.lastZimFileURLSnapshot = lastZimFileURLSnapshot
        self.lastIndexFolderURLSnapshot = lastIndexFolderURLSnapshot
        
        super.init()
        addCondition(MutuallyExclusive<ZimMultiReader>())
        name = String(self)
    }
    
    override func execute() {
        defer {finish()}
        
        currentZimFileURLSnapshot = getCurrentZimFileURLsInDocDir()
        currentIndexFolderURLSnapshot = getCurrentIndexFolderURLsInDocDir()
        
        let indexFolderHasDeletions = lastIndexFolderURLSnapshot.subtract(currentIndexFolderURLSnapshot).count > 0
        
        if indexFolderHasDeletions {
            lastZimFileURLSnapshot.removeAll()
        }
        
        updateReaders()
        context.performBlockAndWait {self.updateCoreData()}
        
        context.performBlockAndWait {self.context.saveIfNeeded()}
        NSManagedObjectContext.mainQueueContext.performBlockAndWait {NSManagedObjectContext.mainQueueContext.saveIfNeeded()}
    }
    
    override func operationDidFinish(errors: [ErrorType]) {
        print("Scan finshed, lasted for \(-time.timeIntervalSinceNow) seconds.")
    }
    
    private func updateReaders() {
        let addedZimFileURLs = currentZimFileURLSnapshot.subtract(lastZimFileURLSnapshot)
        let removedZimFileURLs = lastZimFileURLSnapshot.subtract(currentZimFileURLSnapshot)
        
        ZimMultiReader.shared.removeReaders(removedZimFileURLs)
        ZimMultiReader.shared.addReaders(addedZimFileURLs)
        ZimMultiReader.shared.producePIDMap()
    }
    
    private func updateCoreData() {
        let localBooks = Book.fetchLocal(context)
        let zimReaderIDs = Set(ZimMultiReader.shared.readers.keys)
        let addedZimFileIDs = zimReaderIDs.subtract(Set(localBooks.keys))
        let removedZimFileIDs = Set(localBooks.keys).subtract(zimReaderIDs)
        
        for id in removedZimFileIDs {
            guard let book = localBooks[id] else {continue}
            if book.articles.filter({ $0.isBookmarked }).count > 0 {
                book.state = .Retained
            } else {
                if let _ = book.meta4URL {
                    book.state = .Cloud
                } else {
                    context.deleteObject(book)
                }
            }
        }
        
        for id in addedZimFileIDs {
            guard let reader = ZimMultiReader.shared.readers[id],
                let book: Book = {
                    let book = Book.fetch(id, context: NSManagedObjectContext.mainQueueContext)
                    return book ?? Book.add(reader.metaData, context: NSManagedObjectContext.mainQueueContext)
                }() else {return}
            book.state = .Local
            book.hasIndex = reader.hasIndex()
            book.hasPic = !reader.fileURL.absoluteString!.containsString("nopic")
            if let downloadTask = book.downloadTask {context.deleteObject(downloadTask)}
        }
        
        for (id, book) in localBooks {
            guard !context.deletedObjects.contains(book) else {continue}
            guard let reader = ZimMultiReader.shared.readers[id] else {return}
            book.hasIndex = reader.hasIndex()
        }
        
        if localBooks.count == 0 && addedZimFileIDs.count >= 1 {
            firstBookAdded = true
        }
    }
    
    // MARK: - Helper
    
    private func getCurrentZimFileURLsInDocDir() -> Set<NSURL> {
        var urls = NSFileManager.getContents(dir: NSFileManager.docDirURL)
        let keys = [NSURLIsDirectoryKey]
        urls = urls.filter { (url) -> Bool in
            guard let values = try? url.resourceValuesForKeys(keys),
                let isDirectory = (values[NSURLIsDirectoryKey] as? NSNumber)?.boolValue where isDirectory == false else {return false}
            guard let pathExtension = url.pathExtension?.lowercaseString where pathExtension.containsString("zim") else {return false}
            return true
        }
        return Set(urls)
    }
    
    private func getCurrentIndexFolderURLsInDocDir() -> Set<NSURL> {
        var urls = NSFileManager.getContents(dir: NSFileManager.docDirURL)
        let keys = [NSURLIsDirectoryKey]
        urls = urls.filter { (url) -> Bool in
            guard let values = try? url.resourceValuesForKeys(keys),
                let isDirectory = (values[NSURLIsDirectoryKey] as? NSNumber)?.boolValue where isDirectory == true else {return false}
            guard let pathExtension = url.pathExtension?.lowercaseString where pathExtension == "idx" else {return false}
            return true
        }
        return Set(urls)
    }

}
