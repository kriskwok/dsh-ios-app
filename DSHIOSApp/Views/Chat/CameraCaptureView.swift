import SwiftUI
import AVFoundation

// MARK: - Camera Capture View

/// Full-screen camera with two phases: live capture → captured preview with submit.
struct CameraCaptureView: View {
    let onCapture: (UIImage) -> Void
    let onClose: () -> Void

    @StateObject private var camera = CameraModel()
    @State private var capturedImage: UIImage?
    @State private var isFlashOn = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = capturedImage {
                capturedPreview(image)
            } else {
                liveCamera
            }
        }
        .statusBarHidden(true)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Live Camera

    private var liveCamera: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        isFlashOn.toggle()
                        camera.setTorch(on: isFlashOn)
                    } label: {
                        Image(systemName: isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isFlashOn ? .yellow : .white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!camera.hasTorch)
                    .opacity(camera.hasTorch ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom controls
                VStack(spacing: 16) {
                    Text(camera.isCapturing ? "正在拍照…" : "点击按钮拍照")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))

                    Button {
                        camera.capture { image in
                            Task { @MainActor in
                                if let image {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        capturedImage = image
                                    }
                                }
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isCapturing)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Captured Preview

    private func capturedPreview(_ image: UIImage) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom: retake + submit
                HStack(spacing: 20) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            capturedImage = nil
                        }
                    } label: {
                        Text("重拍")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 48)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        onCapture(image)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                            Text("提交")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 120, height: 48)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 28)
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Camera Preview (UIKit wrapper)

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

// MARK: - Camera Model

@MainActor
final class CameraModel: ObservableObject {
    let session = AVCaptureSession()
    @Published var isCapturing = false
    private let output = AVCapturePhotoOutput()
    private var photoDelegate: PhotoDelegate?
    private var currentDevice: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "com.dsh.camera.session")

    var hasTorch: Bool {
        currentDevice?.hasTorch ?? false
    }

    func start() {
        guard session.inputs.isEmpty else {
            if !session.isRunning {
                sessionQueue.async { self.session.startRunning() }
            }
            return
        }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            return
        }
        currentDevice = device
        session.addInput(input)
        session.addOutput(output)
        sessionQueue.async { self.session.startRunning() }
    }

    func stop() {
        if session.isRunning {
            sessionQueue.async { self.session.stopRunning() }
        }
    }

    func setTorch(on: Bool) {
        guard let device = currentDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true

        let settings = AVCapturePhotoSettings()
        if let preview = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: preview]
        }

        let delegate = PhotoDelegate { [weak self] data in
            Task { @MainActor in
                let image = data.flatMap { UIImage(data: $0) }
                self?.isCapturing = false
                completion(image)
            }
        }
        photoDelegate = delegate
        output.capturePhoto(with: settings, delegate: delegate)
    }
}

// MARK: - Photo Capture Delegate

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Data?) -> Void

    init(completion: @escaping (Data?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            print("Camera capture error: \(error)")
            completion(nil)
            return
        }
        let data = photo.fileDataRepresentation()
        completion(data)
    }
}
