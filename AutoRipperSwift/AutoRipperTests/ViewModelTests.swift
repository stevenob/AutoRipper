import XCTest
@testable import AutoRipper

// MARK: - EncodeViewModel Tests

@MainActor
final class EncodeViewModelTests: XCTestCase {

    func testInitialState() {
        let vm = EncodeViewModel()
        XCTAssertNil(vm.inputFile)
        XCTAssertNil(vm.outputFile)
        XCTAssertEqual(vm.progress, 0)
        XCTAssertFalse(vm.isEncoding)
        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(vm.presets.isEmpty)
        XCTAssertTrue(vm.audioTracks.isEmpty)
        XCTAssertTrue(vm.subtitleTracks.isEmpty)
        XCTAssertTrue(vm.selectedAudioTracks.isEmpty)
        XCTAssertTrue(vm.selectedSubtitleTracks.isEmpty)
        XCTAssertEqual(vm.statusText, "Idle")
    }

    func testAutoSelectPreset1080p() {
        let vm = EncodeViewModel()
        vm.autoSelectPreset(resolution: "1920x1080")
        XCTAssertEqual(vm.selectedPreset, "H.265 Apple VideoToolbox 1080p")
    }

    func testAutoSelectPreset4K() {
        let vm = EncodeViewModel()
        vm.autoSelectPreset(resolution: "3840x2160")
        XCTAssertEqual(vm.selectedPreset, "H.265 Apple VideoToolbox 2160p 4K")
    }

    func testAutoSelectPresetInvalidDoesNotChange() {
        let vm = EncodeViewModel()
        let original = vm.selectedPreset
        vm.autoSelectPreset(resolution: "invalid")
        XCTAssertEqual(vm.selectedPreset, original)
    }

    func testAbortResetsState() {
        let vm = EncodeViewModel()
        vm.isEncoding = true
        vm.progress = 0.5
        vm.progressText = "Encoding..."

        vm.abort()

        XCTAssertFalse(vm.isEncoding)
        XCTAssertEqual(vm.progress, 0)
        XCTAssertEqual(vm.progressText, "")
        XCTAssertEqual(vm.statusText, "Aborted")
    }

    func testEncodeRequiresInputFile() {
        let vm = EncodeViewModel()
        vm.inputFile = nil
        vm.encode()
        XCTAssertFalse(vm.isEncoding)
    }

    func testEncodeDoesNotStartWhileEncoding() {
        let vm = EncodeViewModel()
        vm.inputFile = URL(fileURLWithPath: "/tmp/test.mkv")
        vm.isEncoding = true
        let progressBefore = vm.progress
        vm.encode()
        // Should not reset progress since it's already encoding
        XCTAssertEqual(vm.progress, progressBefore)
    }
}

// MARK: - RipViewModel Tests

@MainActor
final class RipViewModelTests: XCTestCase {

    func testInitialState() {
        let vm = RipViewModel()
        XCTAssertNil(vm.discInfo)
        XCTAssertFalse(vm.isScanning)
        XCTAssertFalse(vm.isRipping)
        XCTAssertEqual(vm.ripProgress, 0)
        XCTAssertTrue(vm.selectedTitles.isEmpty)
        XCTAssertEqual(vm.statusText, "Idle")
        XCTAssertTrue(vm.logLines.isEmpty)
    }

    func testMinDurationReadsConfig() {
        let vm = RipViewModel()
        XCTAssertEqual(vm.minDuration, AppConfig.shared.minDuration)
    }

    func testAbortResetsState() {
        let vm = RipViewModel()
        vm.isScanning = true
        vm.isRipping = true
        vm.ripProgress = 0.75

        vm.abort()

        XCTAssertFalse(vm.isScanning)
        XCTAssertFalse(vm.isRipping)
        XCTAssertEqual(vm.ripProgress, 0)
        XCTAssertEqual(vm.statusText, "Aborted")
    }

    func testScanDoesNotStartWhileScanning() {
        let vm = RipViewModel()
        vm.isScanning = true
        vm.scanDisc()
        // Should still be scanning, not started a second scan
        XCTAssertTrue(vm.isScanning)
    }

    func testRipRequiresSelectedTitles() {
        let vm = RipViewModel()
        vm.selectedTitles = []
        vm.ripSelected()
        XCTAssertFalse(vm.isRipping)
    }

    func testRipRequiresDiscInfo() {
        let vm = RipViewModel()
        vm.selectedTitles = [0]
        vm.discInfo = nil
        vm.ripSelected()
        XCTAssertFalse(vm.isRipping)
    }
}

// MARK: - QueueViewModel Tests

@MainActor
final class QueueViewModelTests: XCTestCase {

    func testInitialState() {
        let vm = QueueViewModel()
        XCTAssertTrue(vm.jobs.isEmpty)
        XCTAssertEqual(vm.statusLabel, "Idle")
    }

    func testAddJob() {
        let vm = QueueViewModel()
        vm.addJob(discName: "Test Movie", rippedFile: URL(fileURLWithPath: "/tmp/test.mkv"), ripElapsed: 120)
        XCTAssertEqual(vm.jobs.count, 1)
        XCTAssertEqual(vm.jobs[0].discName, "Test Movie")
        XCTAssertEqual(vm.jobs[0].status, .queued)
        XCTAssertEqual(vm.jobs[0].ripElapsed, 120)
    }

    func testStatusLabelWithJobs() {
        let vm = QueueViewModel()
        vm.addJob(discName: "Movie 1", rippedFile: URL(fileURLWithPath: "/tmp/a.mkv"), ripElapsed: 0)
        XCTAssertTrue(vm.statusLabel.contains("Processing"))
    }

    func testStatusLabelIdle() {
        let vm = QueueViewModel()
        XCTAssertEqual(vm.statusLabel, "Idle")
    }

    func testAbortCurrentSetsFailedStatus() {
        let vm = QueueViewModel()
        vm.addJob(discName: "Movie", rippedFile: URL(fileURLWithPath: "/tmp/m.mkv"), ripElapsed: 0)
        // Simulate encoding state
        vm.jobs[0].status = .encoding
        vm.abortCurrent()
        XCTAssertEqual(vm.jobs[0].status, .failed)
        XCTAssertEqual(vm.jobs[0].error, "Aborted by user")
    }

    func testMultipleJobs() {
        let vm = QueueViewModel()
        vm.addJob(discName: "Movie 1", rippedFile: URL(fileURLWithPath: "/tmp/a.mkv"), ripElapsed: 0)
        vm.addJob(discName: "Movie 2", rippedFile: URL(fileURLWithPath: "/tmp/b.mkv"), ripElapsed: 0)
        vm.addJob(discName: "Movie 3", rippedFile: URL(fileURLWithPath: "/tmp/c.mkv"), ripElapsed: 0)
        XCTAssertEqual(vm.jobs.count, 3)
    }
}

// MARK: - ScrapeViewModel Tests

@MainActor
final class ScrapeViewModelTests: XCTestCase {

    func testInitialState() {
        let vm = ScrapeViewModel()
        XCTAssertEqual(vm.discName, "")
        XCTAssertFalse(vm.isScraping)
        XCTAssertTrue(vm.logLines.isEmpty)
    }

    func testScrapeRequiresDiscName() {
        let vm = ScrapeViewModel()
        vm.discName = ""
        vm.destDir = "/tmp"
        vm.scrape()
        XCTAssertFalse(vm.isScraping)
    }

    func testScrapeRequiresDestDir() {
        let vm = ScrapeViewModel()
        vm.discName = "TEST"
        vm.destDir = ""
        vm.scrape()
        XCTAssertFalse(vm.isScraping)
    }
}

// MARK: - SettingsViewModel Tests

@MainActor
final class SettingsViewModelTests: XCTestCase {

    func testInitLoadsFromConfig() {
        let vm = SettingsViewModel()
        XCTAssertEqual(vm.outputDir, AppConfig.shared.outputDir)
        XCTAssertEqual(vm.minDuration, AppConfig.shared.minDuration)
        XCTAssertEqual(vm.autoEject, AppConfig.shared.autoEject)
    }

    func testSaveUpdatesConfig() {
        let vm = SettingsViewModel()
        let newDuration = 999
        vm.minDuration = newDuration
        vm.save(quiet: true)
        XCTAssertEqual(AppConfig.shared.minDuration, newDuration)
        // Restore
        vm.minDuration = 120
        vm.save(quiet: true)
    }
}

// MARK: - Job Model Tests

final class JobExtendedTests: XCTestCase {

    func testJobIdIsUnique() {
        let j1 = Job(discName: "A", rippedFile: URL(fileURLWithPath: "/tmp/a.mkv"))
        // Small delay to ensure different timestamp
        Thread.sleep(forTimeInterval: 0.01)
        let j2 = Job(discName: "B", rippedFile: URL(fileURLWithPath: "/tmp/b.mkv"))
        XCTAssertNotEqual(j1.id, j2.id)
    }

    func testJobStatusTransitions() {
        var job = Job(discName: "Test", rippedFile: URL(fileURLWithPath: "/tmp/t.mkv"))
        XCTAssertEqual(job.status, .queued)

        job.status = .encoding
        XCTAssertEqual(job.status, .encoding)

        job.status = .organizing
        XCTAssertEqual(job.status, .organizing)

        job.status = .done
        XCTAssertEqual(job.status, .done)
    }

    func testJobErrorStorage() {
        var job = Job(discName: "Test", rippedFile: URL(fileURLWithPath: "/tmp/t.mkv"))
        job.error = "Something went wrong"
        job.status = .failed
        XCTAssertEqual(job.error, "Something went wrong")
        XCTAssertEqual(job.status, .failed)
    }
}
