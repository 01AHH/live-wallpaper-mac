import Foundation

/// Watches a directory and fires a callback whenever its contents change —
/// files added, removed, or renamed. Events are debounced so a burst of
/// changes (e.g. a download finishing as a `.part` rename) coalesces into
/// one callback.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
