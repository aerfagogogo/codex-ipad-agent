import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum CameraAttachmentAvailability: Equatable {
    case ready
    case needsAuthorization
    case denied
    case restricted
    case unavailable

    nonisolated static func resolve(
        isCameraAvailable: Bool,
        authorizationStatus: AVAuthorizationStatus
    ) -> Self {
        guard isCameraAvailable else {
            return .unavailable
        }

        switch authorizationStatus {
        case .authorized:
            return .ready
        case .notDetermined:
            return .needsAuthorization
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }
}

@MainActor
enum CameraAttachmentAccess {
    static var currentAvailability: CameraAttachmentAvailability {
        CameraAttachmentAvailability.resolve(
            isCameraAvailable: UIImagePickerController.isSourceTypeAvailable(.camera),
            authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

struct CameraAttachmentPickerRequest: Identifiable, Equatable {
    let id = UUID()
    let targetScope: ComposerDraftScopeKey
}

struct CameraAttachmentAccessIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        case denied
        case restricted
        case unavailable
    }

    let id = UUID()
    let kind: Kind
    let targetScope: ComposerDraftScopeKey

    var title: String {
        switch kind {
        case .denied:
            return L10n.text("ui.camera_access_needed")
        case .restricted:
            return L10n.text("ui.camera_access_restricted")
        case .unavailable:
            return L10n.text("ui.camera_unavailable")
        }
    }

    var message: String {
        switch kind {
        case .denied:
            return L10n.text("ui.allow_camera_access_in_settings_or_choose_a_photo")
        case .restricted:
            return L10n.text("ui.camera_access_is_restricted_choose_a_photo_instead")
        case .unavailable:
            return L10n.text("ui.camera_is_not_available_choose_a_photo_instead")
        }
    }

    var canOpenSettings: Bool {
        kind == .denied
    }
}

enum CameraAttachmentCaptureError: LocalizedError {
    case missingImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return L10n.text("ui.unable_to_read_selected_image")
        case .encodingFailed:
            return L10n.text("ui.image_compression_failed")
        }
    }
}

enum CameraCaptureImageEncoder {
    @MainActor
    static func encode(_ image: UIImage) throws -> Data {
        // 只把解码后的像素重新编码为 JPEG，不复用相机原始文件，避免把 GPS/EXIF
        // 等拍摄元数据带入消息附件。后续仍交给 ImageAttachmentEncoder 统一缩放和限额。
        guard let data = image.jpegData(compressionQuality: 0.92), !data.isEmpty else {
            throw CameraAttachmentCaptureError.encodingFailed
        }
        return data
    }
}

struct CameraAttachmentPicker: UIViewControllerRepresentable {
    typealias Completion = (Result<Data?, Error>) -> Void

    let onComplete: Completion

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        // UI 测试只验证系统相机可稳定拉起并取消，不触发快门或写入照片。
        picker.view.accessibilityIdentifier = "composer.cameraAttachmentPicker"
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onComplete: Completion
        private var didComplete = false

        init(onComplete: @escaping Completion) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            complete(.success(nil))
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                complete(.failure(CameraAttachmentCaptureError.missingImage))
                return
            }

            do {
                complete(.success(try CameraCaptureImageEncoder.encode(image)))
            } catch {
                complete(.failure(error))
            }
        }

        private func complete(_ result: Result<Data?, Error>) {
            // 系统控制器在交互式关闭和 delegate 回调重叠时可能触发多个路径，
            // 这里保证一次拍摄请求最多只消费一次。
            guard !didComplete else {
                return
            }
            didComplete = true
            onComplete(result)
        }
    }
}
