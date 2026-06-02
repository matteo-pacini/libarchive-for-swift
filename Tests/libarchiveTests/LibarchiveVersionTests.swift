import Testing
import libarchive

/// Migrated from the XCTest `LibarchiveTests` version checks. These assert the
/// identity of this XCFramework build: the libarchive version itself plus the
/// bundled compression libraries reported by `archive_version_details()`.
///
/// The suite is `.serialized` on purpose. `archive_version_details()` returns a
/// pointer into libarchive's shared, lazily-initialised static version buffer;
/// converting it with `String(cString:)` from several parameterised cases at
/// once races on that shared state and yields corrupted bytes. Serialising the
/// cases keeps every `String(cString:)` on a single thread.
@Suite("libarchive version details", .serialized)
struct LibarchiveVersionTests {

    /// Substrings `archive_version_details()` must contain in this build: the
    /// libarchive release plus each bundled dependency at its pinned version.
    static let expectedFragments = [
        "libarchive 3.8.7",
        "zlib/1.3.2",
        "bz2lib/1.0.8",
        "liblzma/5.8.3",
        "libzstd/1.5.7",
        "liblz4/1.10.0",
    ]

    @Test(
        "version details report the expected bundled library identities",
        arguments: expectedFragments
    )
    func versionDetailsContains(_ fragment: String) throws {
        let ptr = try #require(archive_version_details(),
                               "archive_version_details() returned NULL")
        let details = String(cString: ptr)
        #expect(details.contains(fragment),
                "expected \"\(fragment)\" in version details: \(details)")
    }

    @Test("archive_version_number() matches this build (3.8.7 -> 3008007)")
    func versionNumberIsSane() {
        // libarchive encodes versions as MMmmmpp, so 3.8.7 -> 3*1_000_000 + 8*1_000 + 7.
        #expect(archive_version_number() == 3_008_007)
    }

    @Test("archive_version_string() is non-empty and names libarchive 3.8.7")
    func versionStringIsSane() throws {
        let ptr = try #require(archive_version_string(),
                               "archive_version_string() returned NULL")
        let version = String(cString: ptr)
        #expect(!version.isEmpty)
        #expect(version.contains("libarchive"))
        #expect(version.contains("3.8.7"))
    }
}
