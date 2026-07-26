import CoreImage

/// Loads PV2's Metal CIKernels from the app bundle's `default.metallib`.
///
/// Kernels are compiled at build time (`-fcikernel` in project.yml); there is
/// no runtime-source fallback — that API is gone. A missing metallib or
/// function name is a build break, not a recoverable condition, so this traps.
enum KernelLibrary {
    private final class BundleToken {}

    private static let data: Data = {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("default.metallib missing — check MTL_COMPILER_FLAGS/-fcikernel in project.yml")
        }
        return data
    }()

    static func color(_ name: String) -> CIColorKernel {
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: data) }
        catch { fatalError("CIColorKernel \(name): \(error)") }
    }

    static func general(_ name: String) -> CIKernel {
        do { return try CIKernel(functionName: name, fromMetalLibraryData: data) }
        catch { fatalError("CIKernel \(name): \(error)") }
    }
}
