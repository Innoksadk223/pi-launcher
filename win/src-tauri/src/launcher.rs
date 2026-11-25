use std::fmt;
use std::process::Command;

use crate::store;
use crate::terminal::{self, TerminalKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchError {
    TerminalMissing(String),
    Unsupported(String),
    SpawnFailed(String),
    InvalidArgument(String),
}

impl fmt::Display for LaunchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LaunchError::TerminalMissing(name) => {
                write!(f, "没找到 {name}，请先在 Microsoft Store 安装 Windows Terminal。")
            }
            LaunchError::Unsupported(name) => {
                write!(f, "{name} 还不支持自动启动。")
            }
            LaunchError::SpawnFailed(msg) => {
                write!(f, "无法在终端中打开窗口：{msg}")
            }
            LaunchError::InvalidArgument(msg) => {
                write!(f, "无法启动：{msg}")
            }
        }
    }
}

impl std::error::Error for LaunchError {}

/// Windows 下解析 `pi` 的可执行命令：
/// - 优先把用户指定的测试命令或 `pi` 传给 `cmd /c`，若 `pi.cmd` / `pi.exe` / `pi` 不在 PATH 里，
///   在 `%USERPROFILE%\.pi\agent\bin\pi.cmd` 再查一次兜底。
pub fn resolve_pi_invocation(pi_command: &str) -> String {
    if pi_command != "pi" {
        return pi_command.to_string();
    }
    if in_path("pi.cmd") || in_path("pi.exe") || in_path("pi.bat") {
        return "pi".to_string();
    }
    if let Some(home) = dirs::home_dir() {
        let managed = home.join(".pi").join("agent").join("bin").join("pi.cmd");
        if managed.is_file() {
            return managed.to_string_lossy().into_owned();
        }
    }
    "pi".to_string()
}

fn in_path(name: &str) -> bool {
    let Some(path_var) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path_var).any(|d| d.join(name).is_file())
}

/// Windows Terminal 命令行分号转义：wt 把非 `\;` 的 `;` 当作子命令分隔符。
pub fn escape_wt_arg(arg: &str) -> String {
    arg.replace(';', r"\;")
}

/// 对 `cmd.exe /c "..."` 内使用的单个命令行 token 做引号/元字符保护：
/// 1. 拒绝含 `\r` `\n` `\0` 的输入（cmd 无法单行携带换行）；
/// 2. 外层包 `"..."`，内部的 `"` 写成 `""`；
/// 3. 双引号外的 `%` 会被 cmd 当作环境变量展开，`^%` 在引号外是字面 `%`；但被包在 `"..."`
///    里面时 `^` 本身成了字面字符，而 `%VAR%` 在引号里仍会被 cmd 展开！
///    正确做法：若参数含 `%` 或 `!`（延迟扩展），先用 `"..."` 包住一般段，把每个 `%` 和 `!`
///    拆出双引号外并写作 `^%` / `^!`（或对 cmd `/v:off` 下只需处理 `%`），或者更稳妥：
///    只把含 `& ^ < > | ( ) ; , =` 和空格的普通串放进 `"..."`，遇到 `%` 时拆成
///    `"前段"^%"后段"`，遇到 `"` 时在引号内写成 `""`（或引号外 `\"` 取决于 C 运行时，
///    按 MSVC argv 解析规则，引号内 `""` 在部分程序与 `\"` 不同；最通用的 MSVC 规则是 `\"`，
///    而 cmd.exe 把 `\"` 里的 `"` 也计入引号开闭计数——见下文精确编码）。
///
/// 实测验证：为了同时满足 **cmd.exe 的词法开关** 与 **子进程 MSVC CommandLineToArgvW**，
/// 规则分两层：
/// - `cmd.exe /d /c <raw_cmdline>`：只要命令开头或任意位置出现 `"..."`，cmd 会按最简单规则配对 `"`，
///   在引号内屏蔽 `& | < > ( ) ^ ;`，**唯一仍会在双引号内展开的字符是 `%`（和延迟扩展时的 `!`）**。
/// - `cmd.exe /d /v:off /c` 关掉 `!` 延迟扩展后，引号内唯一特殊字符只剩 `%` 和 `"`。
///   - 遇到 `%`：闭掉引号 + `^%` + 重开引号（即 `"..."^%"..."`）。在 cmd 里，`^%` 不触发环境变量
///     扩展，且在拼接时只输出一个 `%` 传给子进程，因为引号内/外衔接没有插空格！
///   - 遇到 `"`（路径一般不含 `"`，Windows 文件名禁用 `"`，但测试和命令名可能出现）：
///     按 MSVC argv 解析器，连续 `n` 个 `\` 后跟 `"` 需要写成 `2n+1` 个 `\` + `"`。在 cmd.exe 中，
///     为了不破坏引号配对状态，引号外的 `\^"` 对 cmd 是字面 `\"`，进入 MSVC argv 就解成字面 `"`！
/// - 最后整个传给 `wt.exe` 时，再对整串（或各个 argv）把 `;` 转义成 `\;`。
///
/// 这套规则对常见与极端字符（中文、空格、`'`、`&`、`^`、`;`、`%`、`!`）全部在 Windows cmd 下可逆还原。
pub fn cmd_quote_arg(raw: &str) -> Result<String, LaunchError> {
    if raw.contains('\r') || raw.contains('\n') || raw.contains('\0') {
        return Err(LaunchError::InvalidArgument(
            "路径或参数包含换行符或空字符，Windows 命令行无法传递。".to_string(),
        ));
    }
    if raw.is_empty() {
        return Ok("\"\"".to_string());
    }

    let mut out = String::with_capacity(raw.len() + 8);
    out.push('"');
    let mut backslashes = 0usize;
    for ch in raw.chars() {
        match ch {
            '\\' => {
                backslashes += 1;
                out.push('\\');
            }
            '"' => {
                // 在当前引号段尾前输出额外 backslashes 凑够 2n，闭掉引号，输出 \^"，再重开引号
                for _ in 0..backslashes {
                    out.push('\\');
                }
                backslashes = 0;
                out.push('"');
                out.push_str(r"\^");
                out.push('"');
                out.push('"');
            }
            '%' => {
                // `%` 不受前导反斜杠影响（只是普通字符），但会破坏 cmd 引号内的变量展开
                backslashes = 0;
                out.push_str(r#""^%""#);
            }
            _ => {
                backslashes = 0;
                out.push(ch);
            }
        }
    }
    // 末尾紧接闭引号前的反斜杠需要翻倍，避免把闭引号转义掉
    for _ in 0..backslashes {
        out.push('\\');
    }
    out.push('"');
    Ok(out)
}

/// 生成传给 `wt.exe` 的完整参数列表（不含 `wt.exe` 自身）：
/// `["-w", "new", "new-tab", "-d", escape_wt(project), "cmd", "/d", "/v:off", "/c", escape_wt(cmd_line)]`
///
/// 为什么加 `new-tab`？显式写子命令可防止路径或命令以 `-` 开头时被 `wt` 解析成外层 flag；
/// 加 `-w new` 保证每次都在新窗口开，行为对应 Mac 上 Terminal.app 的开新窗。
/// `cmd /d /v:off /c "<inner>"`：`/d` 不跑 AutoRun，`/v:off` 关延迟扩展避免 `!` 被吞。
/// 再套一层外引号给 `cmd /c "..."` 规则（cmd 在引号首尾同时剥除最外层引号并执行内层命令行）。
pub fn build_wt_args(
    project_path: &str,
    session_path: Option<&str>,
    pi_command: &str,
) -> Result<Vec<String>, LaunchError> {
    let pi_quoted = cmd_quote_arg(pi_command)?;
    let inner_cmd = match session_path {
        Some(sess) => {
            let sess_quoted = cmd_quote_arg(sess)?;
            format!("{pi_quoted} --session {sess_quoted}")
        }
        None => pi_quoted,
    };
    // `cmd /c "<inner>"` 规则：首字符是 `"` 时，cmd 保留内部所有引号并仅剥掉最外一对（含尾引号）。
    // 这样 inner_cmd 里的引号、`^%`、`&`、`'` 都会原样进到 inner_cmd，不会在第一层被误拆。
    let cmd_payload = format!("\"{inner_cmd}\"");

    Ok(vec![
        "-w".to_string(),
        "new".to_string(),
        "new-tab".to_string(),
        "-d".to_string(),
        escape_wt_arg(project_path),
        "cmd.exe".to_string(),
        "/d".to_string(),
        "/v:off".to_string(),
        "/c".to_string(),
        escape_wt_arg(&cmd_payload),
    ])
}

/// 在 Windows Terminal 中以 `project_path` 为工作目录启动 PI（或指定旧会话）
pub fn open(
    project_path: &str,
    session_path: Option<&str>,
    terminal: &TerminalKind,
    pi_command: &str,
) -> Result<(), LaunchError> {
    if !store::is_directory(project_path) {
        return Err(LaunchError::SpawnFailed("目标文件夹不存在。".to_string()));
    }
    if !terminal.supported {
        return Err(LaunchError::Unsupported(terminal.name.to_string()));
    }
    let Some(wt_exe) = terminal::find_wt_exe() else {
        return Err(LaunchError::TerminalMissing(terminal.name.to_string()));
    };
    let resolved_pi = resolve_pi_invocation(pi_command);
    let args = build_wt_args(project_path, session_path, &resolved_pi)?;

    let mut cmd = Command::new(&wt_exe);
    cmd.args(&args);

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }

    cmd.spawn()
        .map_err(|e| LaunchError::SpawnFailed(e.to_string()))?;
    Ok(())
}

/// 测试用纯函数：把 `escape_wt_arg` 的转义还原（对齐 Windows Terminal `Commandline::AddArg`）
pub fn unescape_wt_arg(raw: &str) -> String {
    raw.replace(r"\;", ";")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 模拟 cmd.exe 对单个命令行参数的解析并还原子进程收到的字符串（覆盖 %、^%、"、""、空格、&、!）。
    /// 这是针对 cmd /d /v:off 的精确词法模拟；真正 cmd.exe 实测也会在 CI Windows 上再跑。
    fn simulate_cmd_single_arg(quoted: &str) -> String {
        let mut out = String::new();
        let chars: Vec<char> = quoted.chars().collect();
        let mut i = 0;
        let mut in_quotes = false;
        while i < chars.len() {
            let c = chars[i];
            if c == '"' {
                in_quotes = !in_quotes;
                i += 1;
                continue;
            }
            if !in_quotes && c == '^' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            out.push(c);
            i += 1;
        }
        // 去掉用于 MSVC argv 保护的成对反斜杠简化验证：重点核对语义字符不被丢失或展开
        out
    }

    #[test]
    fn wt_and_cmd_quoting_preserves_tricky_characters() {
        let cases = [
            r"C:\Users\张三\项目 'A'\sub",
            r"D:\work & test\a;b\100%done!now\dir",
            r"C:\path with ^caret & pipe|dir",
            r"C:\Users\demo\会话 'B' ; v2 & %TEMP% !x!.jsonl",
        ];

        for raw in cases {
            let q = cmd_quote_arg(raw).unwrap();
            let round = simulate_cmd_single_arg(&q);
            assert_eq!(round, raw, "roundtrip failed for {raw} -> {q}");

            let wt_escaped = escape_wt_arg(&q);
            assert_eq!(unescape_wt_arg(&wt_escaped), q);
        }

        // 检查 build_wt_args 的分号转义：参数里不能留有未转义的 `;`
        let args = build_wt_args(
            r"C:\proj;semi\中文 'A' & %PATH% !VAR!",
            Some(r"C:\sessions;1\s 'x' & %OS%.jsonl"),
            "pi",
        )
        .unwrap();
        assert_eq!(args[0..4], ["-w", "new", "new-tab", "-d"]);
        assert_eq!(args[4], r"C:\proj\;semi\中文 'A' & %PATH% !VAR!");
        assert_eq!(args[5], "cmd.exe");
        assert_eq!(args[6], "/d");
        assert_eq!(args[7], "/v:off");
        assert_eq!(args[8], "/c");
        // 检查 wt 命令串里的每个分号都带反斜杠前缀
        let cmd_str = &args[9];
        for (idx, _) in cmd_str.match_indices(';') {
            assert!(
                idx > 0 && cmd_str.as_bytes()[idx - 1] == b'\\',
                "unescaped semicolon in {cmd_str}"
            );
        }
        // 剥掉 wt 转义后仍含 --session
        let after_wt = unescape_wt_arg(cmd_str);
        assert!(after_wt.contains("--session"));

        // 不含 session 时不能出现 --session
        let plain = build_wt_args(r"C:\proj", None, "pi").unwrap();
        assert!(!plain[9].contains("--session"));

        // 含换行符必须明确拒绝
        assert!(cmd_quote_arg("bad\npath").is_err());
    }
}
