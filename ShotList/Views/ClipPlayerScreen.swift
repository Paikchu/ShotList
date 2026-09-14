import AVFoundation
import AVKit
import SwiftUI

/// 整屏播放某个分镜已经拍好的视频。
struct ClipPlayerScreen: View {
    let shot: Shot
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("关闭播放")
                }
                .padding(.horizontal, SLSpacing.medium)
                .padding(.top, SLSpacing.small)

                Spacer()

                VStack(spacing: SLSpacing.tiny) {
                    Text("镜头 \(shot.paddedNumber) · \(shot.displayTitle)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let duration = shot.durationText {
                        Text("时长 \(duration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, SLSpacing.medium)
                .padding(.vertical, SLSpacing.small)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, SLSpacing.large)
                .accessibilityElement(children: .combine)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playback, mode: .moviePlayback)
            try? audioSession.setActive(true)

            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

#Preview {
    ClipPlayerScreen(
        shot: Shot(number: 1, title: "开场", clipFileName: "a.mov", recordedAt: Date(), clipDuration: 12),
        url: URL(fileURLWithPath: "/dev/null")
    )
}
