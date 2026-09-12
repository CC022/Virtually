// Linux guest agent 的安装脚本。
//
// 由 autoinstall 的 `late-commands` 执行 —— 那是 Windows 那边 `FirstLogonCommands` 的对应物,
// 区别是它跑在**安装器里**(目标系统挂在 /target),而不是装完第一次登录时。
// 好处:装完第一次开机 agent 就已经在了,不用等谁登录去跑一个 .bat。
//
// agent 本体与两个 systemd 单元在 GuestAgent/linux/,由 UbuntuSeedDisk 拷到引导盘的 agent/ 目录,
// 这里把它们从盘上搬进 /target。盘按卷标 CIDATA 找,不写死设备名。

import Foundation

public enum LinuxAgent {

    /// agent 在 guest 里的落点。放 /usr/local/lib 而不是 /opt:
    /// 前者在 Debian 策略里就是「本地装的东西」,dpkg 不会去管它。
    public static let installDir = "/usr/local/lib/virtually"

    /// `late-commands` 里的一条 shell 命令(会被包成 YAML 块标量)。
    ///
    /// 几个必须这么写的点:
    ///   * 挂 CIDATA 用卷标,不用设备名 —— 设备名取决于挂了几块盘
    ///   * 用 `curtin in-target --` 在目标系统里跑 systemctl,不是在安装器里跑
    ///   * 会话侧单元用符号链接放进 graphical-session.target.wants,
    ///     `systemctl --user enable` 在安装器里没有用户总线,做不了
    public static func installScript(username: String) -> String {
        """
        set -e
        SEED=$(mktemp -d)
        mount -o ro "$(blkid -L CIDATA)" "$SEED"
        install -d \(installDir)
        install -d /target\(installDir)
        install -m 0755 "$SEED/agent/virtually-agent.py" /target\(installDir)/virtually-agent.py
        install -m 0644 "$SEED/agent/virtually-agent.service" /target/etc/systemd/system/virtually-agent.service
        install -m 0644 "$SEED/agent/virtually-session.service" /target/etc/systemd/user/virtually-session.service
        install -d /target/etc/systemd/user/graphical-session.target.wants
        ln -sf /etc/systemd/user/virtually-session.service \\
            /target/etc/systemd/user/graphical-session.target.wants/virtually-session.service
        curtin in-target -- systemctl enable virtually-agent.service
        umount "$SEED"
        rmdir "$SEED"
        """
    }
}
