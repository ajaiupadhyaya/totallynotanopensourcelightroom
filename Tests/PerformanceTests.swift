import XCTest
@testable import PhotoEditor

final class PerformanceTests: XCTestCase {
    func testRenderSchedulerCoalescesBursts() {
        let scheduler = RenderScheduler()
        let lock = NSLock()
        var executions = 0

        for _ in 0..<20 {
            scheduler.schedule {
                lock.lock()
                executions += 1
                lock.unlock()
            }
        }

        let expectation = expectation(description: "scheduler flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertLessThan(executions, 20, "Stale preview frames should be dropped.")
        XCTAssertGreaterThan(executions, 0)
    }

    func testPreviewRenderLatencyBudget() {
        let renderer = EditRenderer()
        let source = TestSupport.solidImage(red: 0.4, green: 0.5, blue: 0.6, size: 1600)
        var stack = EditStack()
        stack.exposure = 0.5

        measure {
            _ = renderer.render(source: source, stack: stack)
        }
    }
}
