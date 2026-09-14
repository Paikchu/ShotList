import Foundation

/// 界面目前只有简体中文一种语言。
///
/// 日期、数字默认跟随系统区域设置，在英文系统上会出现
/// 「Monday, Sep 14, 2026」这种和界面语言不一致的显示，
/// 因此把格式化区域固定为简体中文。
/// 将来接入多语言时，把这里改回 `Locale.current` 即可。
nonisolated enum AppLocale {
    static let current = Locale(identifier: "zh-Hans-CN")
}
