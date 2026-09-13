// virtually —— Virtually 的命令行工具,与 app 共用 VirtuallyKit。
//
// 两类命令:
//   离线的,直接操作资源库:list / create / install / resize-disk / inspect-iso / build-tools
//   驱动 app 的:run / send / log / stop / shot
//     run 以调试模式拉起 Virtually.app 并打开一台虚拟机,app 的输出写进日志;
//     send 把命令经 Unix socket 送进 app(命令集见 app 的 ControlServer),再把这段时间的新日志打出来。

import Foundation
import VirtuallyKit

let usage = """
用法：virtually <命令> [选项]

资源库
  list                                   列出虚拟机
  create <名称> [--os windows|ubuntu] [--cpus N] [--memory MB] [--disk GB]
         [--network none|user] [--from-disk <镜像>]
  install <名称> --iso <ISO> [--os windows|ubuntu] [--variant <id>]
         [--username <用户名>] [--password <密码>] [--cpus N] [--memory MB] [--disk GB]
         [--no-run]                      只准备安装介质，不启动虚拟机
  resize-disk <名称> <GB>                扩大系统盘（需关机且未挂起），下次启动时自动扩展系统分区
  inspect-iso <ISO>                      识别镜像的系统并列出可安装的版本
  build-tools [<输出路径>]               重新生成 Windows 工具盘（默认位于 Application Support）

调试（驱动 app）
  run --vm <路径> [--ramfb] [--vblk-probe] [--tools] [--cursor-debug] [--guest-cursor]
      [--iso <ISO>] [--boot-img <raw>] [--display-size <宽>x<高>]
  send <命令…> [--wait 秒]               向调试实例发送命令，命令列表见 Virtually/Control/ControlServer.swift
  log [行数]                             显示调试日志的最后几行
  stop                                   挂起虚拟机并退出调试实例
  shot <输出.png> [x,y,w,h]              从帧缓冲截取虚拟机画面

通用选项
  --app <Virtually.app>                  默认使用与本工具同目录的 app，其次按 bundle ID 查找
  --library <目录>                       默认使用偏好设置中的资源库位置
"""

setvbuf(stdout, nil, _IOLBF, 0)

var args = Arguments(Array(CommandLine.arguments.dropFirst()))
let command = args.next() ?? "help"

do {
    switch command {
    case "list":        try LibraryCommands.list(&args)
    case "create":      try LibraryCommands.create(&args)
    case "install":     try LibraryCommands.install(&args)
    case "resize-disk": try LibraryCommands.resizeDisk(&args)
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
        throw CLIError("未知命令：\(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
