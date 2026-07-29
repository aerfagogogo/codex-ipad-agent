import AVFoundation
import UIKit
import XCTest
@testable import MimiRemote

final class CameraAttachmentTests: XCTestCase {
    func testAvailabilityRequiresBothCameraAndAuthorization() {
        XCTAssertEqual(
            CameraAttachmentAvailability.resolve(
                isCameraAvailable: false,
                authorizationStatus: .authorized
            ),
            .unavailable
        )
        XCTAssertEqual(
            CameraAttachmentAvailability.resolve(
                isCameraAvailable: true,
                authorizationStatus: .authorized
            ),
            .ready
        )
        XCTAssertEqual(
            CameraAttachmentAvailability.resolve(
                isCameraAvailable: true,
                authorizationStatus: .notDetermined
            ),
            .needsAuthorization
        )
        XCTAssertEqual(
            CameraAttachmentAvailability.resolve(
                isCameraAvailable: true,
                authorizationStatus: .denied
            ),
            .denied
        )
        XCTAssertEqual(
            CameraAttachmentAvailability.resolve(
                isCameraAvailable: true,
                authorizationStatus: .restricted
            ),
            .restricted
        )
    }

    @MainActor
    func testCapturedImageReusesExistingAttachmentSizeLimits() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2_400, height: 1_800),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_800))
        }

        let cameraJPEG = try CameraCaptureImageEncoder.encode(image)
        let prepared = try ImageAttachmentEncoder.prepare(cameraJPEG)

        XCTAssertFalse(cameraJPEG.isEmpty)
        XCTAssertLessThanOrEqual(
            max(prepared.pixelWidth, prepared.pixelHeight),
            ImageAttachmentEncoder.maximumPixelDimension
        )
        XCTAssertLessThanOrEqual(
            prepared.encodedByteCount,
            ImageAttachmentEncoder.targetEncodedByteCount
        )
        XCTAssertTrue(prepared.dataURL.hasPrefix("data:image/jpeg;base64,"))
    }

    func testOnlyDeniedIssueOffersSettingsRecovery() {
        let scope = ComposerDraftScopeKey.none
        XCTAssertTrue(
            CameraAttachmentAccessIssue(kind: .denied, targetScope: scope).canOpenSettings
        )
        XCTAssertFalse(
            CameraAttachmentAccessIssue(kind: .restricted, targetScope: scope).canOpenSettings
        )
        XCTAssertFalse(
            CameraAttachmentAccessIssue(kind: .unavailable, targetScope: scope).canOpenSettings
        )
    }
}
