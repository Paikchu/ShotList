#!/usr/bin/env swift
//
// 生成 1024×1024 的 App 图标：分镜清单的三行「镜头条目」，前两行已拍、第三行待拍。
// 用法：swift Tools/generate-icon.swift <输出路径>
//

import AppKit
import CoreGraphics
import Foundation

let sidePixels = 1024
let side = CGFloat(sidePixels)
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: sidePixels,
    height: sidePixels,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("无法创建绘图上下文")
}

let canvas = CGRect(x: 0, y: 0, width: side, height: side)

// 背景：深靛蓝到亮蓝的对角渐变（与 App 的强调色同色系）
let backgroundColors = [
    CGColor(red: 0.078, green: 0.118, blue: 0.353, alpha: 1),
    CGColor(red: 0.176, green: 0.400, blue: 0.925, alpha: 1)
] as CFArray

guard let background = CGGradient(
    colorsSpace: colorSpace,
    colors: backgroundColors,
    locations: [0, 1]
) else {
    fatalError("无法创建渐变")
}

context.drawLinearGradient(
    background,
    start: CGPoint(x: 0, y: side),
    end: CGPoint(x: side, y: 0),
    options: []
)

// 右上角一层柔光，让图标不至于太死板
if let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
) {
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: side * 0.82, y: side * 0.86),
        startRadius: 0,
        endCenter: CGPoint(x: side * 0.82, y: side * 0.86),
        endRadius: side * 0.62,
        options: []
    )
}

// 三行镜头条目
let rowHeight: CGFloat = 116
let rowGap: CGFloat = 62
let circleDiameter = rowHeight
let barCorner = rowHeight / 2
let circleX: CGFloat = 232
let barX: CGFloat = 404
let barWidth: CGFloat = 388
let totalHeight = rowHeight * 3 + rowGap * 2
let startY = (CGFloat(side) - totalHeight) / 2

/// 用白色绘制一行：左边编号圆点 + 右边标题条
func drawRow(index: Int, alpha: CGFloat) {
    let y = startY + CGFloat(index) * (rowHeight + rowGap)

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))

    let circle = CGRect(x: circleX, y: y, width: circleDiameter, height: circleDiameter)
    context.fillEllipse(in: circle)

    let bar = CGRect(x: barX, y: y, width: barWidth, height: rowHeight)
    let barPath = CGPath(
        roundedRect: bar,
        cornerWidth: barCorner,
        cornerHeight: barCorner,
        transform: nil
    )
    context.addPath(barPath)
    context.fillPath()
}

// 已拍的两行实心，待拍的第三行半透明
drawRow(index: 0, alpha: 1.0)
drawRow(index: 1, alpha: 1.0)
drawRow(index: 2, alpha: 0.42)

guard let image = context.makeImage() else {
    fatalError("无法生成位图")
}

let representation = NSBitmapImageRep(cgImage: image)
representation.size = NSSize(width: sidePixels, height: sidePixels)

guard let data = representation.representation(using: .png, properties: [:]) else {
    fatalError("无法编码 PNG")
}

try data.write(to: URL(fileURLWithPath: outputPath))
print("已生成 App 图标：\(outputPath)")
