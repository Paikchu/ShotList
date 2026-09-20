import AVFoundation
import AVKit
import SwiftUI

/// 整屏播放某个镜头里的某一条片段。
struct ClipPlayerScreen: View {
    let shot: Shot
    /// 正在播的这一条
    let clip: ShotClip
    /// 它是这个镜头的第几条（从 1 开始）
    let takeIndex: Int
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
                    .accessibilityLabel("关闭")
                }
                .padding(.horizontal, SLSpacing.medium)
                .padding(.top, SLSpacing.small)

                Spacer()

                VStack(spacing: SLSpacing.tiny) {
                    Text("镜头 \(shot.paddedNumber) · 第 \(takeIndex) 条")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if shot.hasNote {
                        Text(shot.note)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }

                    if let duration = clip.durationText {
                        IconValue(systemImage: "clock", text: duration)
                            .font(.caption)
                            .accessibilityLabel("时长 \(duration)")
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
            // 播放期间把音频会话切成了 .playback，退出时必须归还音频焦点，
            // 否则别的 App 的音乐在离开本页后不会恢复。
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }
}

#Preview {
    ClipPlayerScreen(
        shot: Shot(
            number: 1,
            note: "无人机缓慢上升，配一句开场旁白",
            clips: [ShotClip(fileName: "a.mov", duration: 12, recordedAt: Date())]
        ),
        clip: ShotClip(fileName: "a.mov", duration: 12, recordedAt: Date()),
        takeIndex: 1,
        url: URL(fileURLWithPath: "/dev/null")
    )
}
