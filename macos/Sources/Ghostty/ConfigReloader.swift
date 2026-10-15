import Foundation

/// Watches the files a configuration was loaded from and asks for a reload
/// once they settle.
///
/// Editors save by renaming a temporary file into place or by deleting and
/// recreating the original, so watching file descriptors is not enough: the
/// watcher follows paths, re-resolves them after every event, and keeps
/// watching after a load is rejected so a later fix reloads on its own.
/// A directory is watched for the file that should appear inside it, which
/// is how a default location that does not exist yet gets picked up.
final class ConfigReloader {
    /// How long to wait after the last event before reloading. Editors
    /// emit several events per save, and a reload should see the file
    /// after all of them.
    static let settleDelay: TimeInterval = 0.2

    /// Reports that the watched paths changed and have since stayed quiet.
    var onChange: () -> Void = {}

    init(delivery: DispatchQueue = .main) {
        self.delivery = delivery
    }

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.config-watch")
    /// Where settled changes are delivered. The app wants them on the main
    /// queue because a reload touches app state; tests inject their own.
    private let delivery: DispatchQueue
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var descriptors: [String: Int32] = [:]
    /// Whether the path itself existed when its watch was last opened. A path
    /// watched through its parent reloads only once the path appears.
    private var existed: [String: Bool] = [:]
    /// Bumped each time a path is re-opened. A cancelled source's handler runs
    /// after the replacement has been stored, so it must only clear state that
    /// still belongs to its own generation.
    private var generation: [String: UInt] = [:]
    private var settle: DispatchWorkItem?

    /// Replace the watched set. A path that is already watched is left
    /// alone; everything else is closed. Passing an empty list stops
    /// watching without forgetting `onChange`.
    func watch(_ paths: [String]) {
        queue.async { [weak self] in
            self?.updateWatch(Set(paths))
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.settle?.cancel()
            self.settle = nil
            self.updateWatch([])
        }
    }

    deinit {
        // The cancel handler closes the descriptor. Closing it here as well
        // would close it twice, and the second close can hit a descriptor
        // number that has since been reused.
        for source in sources.values {
            source.cancel()
        }
    }

    private func updateWatch(_ wanted: Set<String>) {
        dispatchPrecondition(condition: .onQueue(queue))
        for path in sources.keys where !wanted.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in wanted where sources[path] == nil {
            watch(path)
        }
    }

    private func watch(_ path: String) {
        // A path that does not exist yet is watched through its parent, which
        // is what reports the entry being created. The parent has to exist;
        // a path whose parent directory is also missing is not watched.
        let exists = FileManager.default.fileExists(atPath: path)
        existed[path] = exists
        let target = exists ? path : (path as NSString).deletingLastPathComponent
        let descriptor = open(target, O_EVTONLY)
        guard descriptor >= 0 else { return }
        descriptors[path] = descriptor
        generation[path, default: 0] += 1
        let opened = generation[path]!

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .link, .extend, .attrib],
            queue: queue)
        source.setEventHandler { [weak self] in
            self?.pathChanged(path)
        }
        source.setCancelHandler { [weak self] in
            defer { close(descriptor) }
            guard let self, self.generation[path] == opened else { return }
            self.descriptors.removeValue(forKey: path)
            self.existed.removeValue(forKey: path)
        }
        sources[path] = source
        source.resume()
    }

    private func pathChanged(_ path: String) {
        let wasThere = existed[path] ?? false
        // The event may be the path appearing or disappearing. Re-open so the
        // descriptor follows whichever of the path or its parent exists now.
        // watch records the new existence before the old source's cancel
        // handler runs, so read it before cancelling.
        let nowThere = FileManager.default.fileExists(atPath: path)
        sources.removeValue(forKey: path)?.cancel()
        watch(path)
        // Watched through its parent, and the path still does not exist: the
        // event belongs to another entry in that parent.
        if !wasThere, !nowThere { return }
        scheduleReload()
    }

    private func scheduleReload() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // A reload touches app state, so the app delivers on the main
            // queue. The hop also keeps onChange off the watch queue, so a
            // callback that calls watch or stop cannot deadlock on it.
            self?.delivery.async {
                self?.onChange()
            }
        }
        settle = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }
}
