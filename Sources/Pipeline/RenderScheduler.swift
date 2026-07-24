import Foundation

/// Coalesces preview render requests so rapid slider scrubbing drops stale frames.
final class RenderScheduler {
    private let queue = DispatchQueue(label: "com.photoeditor.render", qos: .userInteractive)
    private var pendingWork: DispatchWorkItem?
    private var generation = 0

    func schedule(after delay: TimeInterval = 0, _ work: @escaping () -> Void) {
        generation += 1
        let token = generation
        pendingWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation else { return }
            work()
        }
        pendingWork = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        generation += 1
        pendingWork?.cancel()
        pendingWork = nil
    }
}
