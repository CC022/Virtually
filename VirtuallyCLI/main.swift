// virtually —— Virtually 的命令行工具,与 app 共用 VirtuallyKit。
//
// 两类命令:
//   离线的,直接操作资源库:list / create / install / inspect-iso / build-tools
//   驱动 app 的:run / send / log / stop / shot
//     run 以调试模式拉起 Virtually.app 并打开一台虚拟机,app 的输出写进日志;
//     send 把命令经 Unix socket 送进 app(命令集见 app 的 ControlServer),再把这段时间的新日志打出来。

import Foundation
import VirtuallyKit

let usage = """
用法: virtually <命令> [参数]

资源库
  list                                   列出虚拟机
  create <名字> [--os windows|ubuntu] [--cpus N] [--memory MB] [--disk GB]
         [--network none|user] [--from-disk <镜像>]
  install <名字> --iso <ISO> [--os windows|ubuntu] [--variant <id>] [--virtio-iso <ISO>]
         [--username <用户>] [--password <密码>] [--cpus N] [--memory MB] [--disk GB]
         [--no-run]                      准备好介质后默认用 run 开机开始安装
  inspect-iso <ISO>                      识别系统并列出可装的变体
  build-tools [<输出>]                   重建 Windows 工具盘(默认在 Application Support)

驱动 app(调试)
  run --vm <包> [--ramfb] [--vblk-probe] [--tools] [--cursor-debug] [--guest-cursor]
      [--iso <ISO>] [--boot-img <raw>] [--display-size <宽>x<高>]
  send <命令…> [--wait 秒]              命令集见 Virtually/Control/ControlServer.swift
  log [行数]
  stop                                   先挂起再退出
  shot <输出.png> [x,y,w,h]              从共享帧缓冲截图

通用
  --app <Virtually.app>                  默认找与本工具同目录的,其次按 bundle ID 找已安装的
  --library <目录>                       默认用偏好设置里的资源库位置
"""

setvbuf(stdout, nil, _IOLBF, 0)

var args = Arguments(Array(CommandLine.arguments.dropFirst()))
let command = args.next() ?? "help"

do {
    switch command {
    case "list":        try LibraryCommands.list(&args)
    case "create":      try LibraryCommands.create(&args)
    case "install":     try LibraryCommands.install(&args)
    case "inspect-iso": try LibraryCommands.inspectISO(&args)
    case "build-tools": try LibraryCommands.buildTools(&args)
    case "run":         try AppControl.run(&args)
    case "send":        try AppControl.send(&args)
    case "log":         try AppControl.log(&args)
    case "stop":        try AppControl.stop(&args)
    case "shot":        try AppControl.shot(&args)
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError("未知命令 \(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
