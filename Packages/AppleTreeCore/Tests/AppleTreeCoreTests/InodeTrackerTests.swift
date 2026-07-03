import Testing
@testable import AppleTreeCore

@Suite("InodeTracker")
struct InodeTrackerTests {
    @Test("first sighting of a (device, inode) pair is reported as first, subsequent ones are not")
    func dedupesRepeatedInode() {
        let tracker = InodeTracker()

        let first = tracker.markSeenReturningIsFirst(device: 1, inode: 42)
        let second = tracker.markSeenReturningIsFirst(device: 1, inode: 42)
        let third = tracker.markSeenReturningIsFirst(device: 1, inode: 42)

        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("same inode number on different devices is treated as distinct")
    func sameInodeDifferentDeviceIsDistinct() {
        let tracker = InodeTracker()

        let onDeviceOne = tracker.markSeenReturningIsFirst(device: 1, inode: 42)
        let onDeviceTwo = tracker.markSeenReturningIsFirst(device: 2, inode: 42)

        #expect(onDeviceOne)
        #expect(onDeviceTwo)
    }
}
