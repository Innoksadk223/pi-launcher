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

/// 把一个 token 变成 cmd 下不会被拆开的写法。
///
/// 这条链有三层，每一层都会动引号，必须一起算：
///
/// 1. **我们**：token 包进 `"..."`。引号内 `& | < > ( ) ^ ; , = @ ' 空格` 全是字面量，
///    唯一还会展开的是 `%`（`/v:off` 之后 `!` 不再是特殊字符）。
///    所以遇到 `%` 就闭引号、写 `^%`、再开引号：`"C:\100"^%"done"`。cmd 拼接时只输出一个 `%`。
/// 2. **Windows Terminal**：它把各个位置参数用空格拼起来，**只对含空格的 token 再包一层 `"`**，
///    而且不转义里面的 `"`（见 AppCommandlineArgs::_getNewTerminalArgs）。
///    也就是说外层这层引号由它给，我们不能再自己包一层，否则会多出一对、把命令粘成一个程序名。
/// 3. **cmd /c**：命令余下部分以 `"` 开头且引号多于两个时，剥掉最外层那一对。
///    正好把第 2 层补的那对吃掉，回到我们第 1 层写好的样子。
///
/// 含 `"` 的 token 直接拒绝：Windows 文件名里不可能出现 `"`，真出现说明输入不是正常路径，
/// 与其猜测怎么转义，不如明说传不过去（换行、空字符同理）。
pub fn cmd_quote_arg(raw: &str) -> Result<String, LaunchError> {
    if raw.contains('\r') || raw.contains('\n') || raw.contains('\0') {
        return Err(LaunchError::InvalidArgument(
            "路径或参数包含换行符或空字符，Windows 命令行无法传递。".to_string(),
        ));
    }
    if raw.contains('"') {
        return Err(LaunchError::InvalidArgument(
            "路径或参数包含双引号，Windows 命令行无法可靠传递。".to_string(),
        ));
    }
    if raw.is_empty() {
        return Ok("\"\"".to_string());
    }

    let mut out = String::with_capacity(raw.len() + 8);
    let mut backslashes = 0usize;
    out.push('"');
    for ch in raw.chars() {
        match ch {
            '\\' => {
                backslashes += 1;
                out.push('\\');
            }
            // 引号内仍会展开：闭引号 + ^% + 重开引号，cmd 拼接后仍是字面 %，且不留空格
            '%' => {
                out.push_str(&quote_prefix_backslashes(&mut backslashes));
                out.push_str("\"^%\"");
            }
            _ => {
                backslashes = 0;
                out.push(ch);
            }
        }
    }
    out.push_str(&quote_prefix_backslashes(&mut backslashes));
    out.push('"');
    Ok(out)
}


/// 反斜杠紧接着引号时，MSVC 的 argv 解析会把 `\"` 当成「字面引号」，引号配对随之错位。
/// 所以每次要发一个「真正的引号」之前，先把前面的反斜杠数补成偶数。
/// 返回需要补写的反斜杠（并清零计数）。
fn quote_prefix_backslashes(backslashes: &mut usize) -> String {
    let extra = if *backslashes % 2 == 1 {
        *backslashes = 0;
        "\\".to_string()
    } else {
        *backslashes = 0;
        String::new()
    };
    extra
}

/// 生成传给 `wt.exe` 的完整参数列表（不含 `wt.exe` 自身）：
/// `["-w", "new", "new-tab", "-d", escape_wt(project), "cmd", "/d", "/v:off", "/c", escape_wt(cmd_line)]`
///
/// 为什么加 `new-tab`？显式写子命令可防止路径或命令以 `-` 开头时被 `wt` 解析成外层 flag；
/// 加 `-w new` 保证每次都在新窗口开，行为对应 Mac 上 Terminal.app 的开新窗。
/// `cmd /d /v:off /c <inner>`：`/d` 不跑 AutoRun，`/v:off` 关延迟扩展避免 `!` 被吞。
/// `<inner>` 不再自带外层引号——那一对由 wt 补、由 cmd /c 剥，见 [`cmd_quote_arg`] 的三层说明。
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
    // 不能再自己包一层引号：wt 会替含空格的 token 补一对，cmd /c 再剥掉那一对，
    // 三层刚好抵消、回到 inner_cmd 本身。多包一层会变成两组引号互不配对。
    let cmd_payload = inner_cmd;

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

    // ── 整条链的模拟器 ───────────────────────────────────────────
    // 只测「单个 cmd 参数」会漏掉中间两层：wt 会重新拼命令行并补引号，cmd /c 又会剥一层。
    // 这里把三层都写出来，断言最后一层交到子进程手里的 argv。

    /// 第 0 层：`std::process::Command` 在 Windows 上把 argv 拼成命令行。
    /// 与 Rust 标准库同样遵循 MSVC 规则：含空白或引号才加引号，内部 `"` 写 `\"`，
    /// 引号前的反斜杠数翻倍。
    fn encode_create_process(argv: &[String]) -> String {
        let mut out = String::new();
        for (i, arg) in argv.iter().enumerate() {
            if i > 0 {
                out.push(' ');
            }
            if arg.is_empty() {
                out.push_str("\"\"");
                continue;
            }
            if !arg.chars().any(|c| c == ' ' || c == '\t' || c == '"') {
                out.push_str(arg);
                continue;
            }
            out.push('"');
            let mut backslashes = 0usize;
            for c in arg.chars() {
                if c == '\\' {
                    backslashes += 1;
                    out.push('\\');
                } else if c == '"' {
                    out.push_str(&"\\".repeat(backslashes + 1));
                    out.push('"');
                    backslashes = 0;
                } else {
                    backslashes = 0;
                    out.push(c);
                }
            }
            out.push_str(&"\\".repeat(backslashes));
            out.push('"');
        }
        out
    }

    /// `CommandLineToArgvW`：进程（这里是 wt.exe）看到的 argv
    fn argv_from_commandline(line: &str) -> Vec<String> {
        let chars: Vec<char> = line.chars().collect();
        let mut out: Vec<String> = Vec::new();
        let mut cur = String::new();
        let mut in_quotes = false;
        let mut have = false;
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if c == '\\' {
                let mut n = 0;
                while i < chars.len() && chars[i] == '\\' {
                    n += 1;
                    i += 1;
                }
                if i < chars.len() && chars[i] == '"' {
                    cur.push_str(&"\\".repeat(n / 2));
                    if n % 2 == 1 {
                        cur.push('"');
                        have = true;
                        i += 1;
                    }
                } else {
                    cur.push_str(&"\\".repeat(n));
                    have = true;
                }
                continue;
            }
            if c == '"' {
                in_quotes = !in_quotes;
                have = true;
                i += 1;
                continue;
            }
            if !in_quotes && (c == ' ' || c == '\t') {
                if have {
                    out.push(std::mem::take(&mut cur));
                    have = false;
                }
                i += 1;
                continue;
            }
            cur.push(c);
            have = true;
            i += 1;
        }
        if have {
            out.push(cur);
        }
        out
    }

    /// 第 2 层：Windows Terminal 把位置参数拼成 profile 命令行。
    /// 只有含空格的 token 会被再包一层 `"`，内部引号不转义（AppCommandlineArgs.cpp）。
    fn wt_join(positionals: &[String]) -> String {
        let mut out = String::new();
        for (i, a) in positionals.iter().enumerate() {
            if i > 0 {
                out.push(' ');
            }
            if a.contains(' ') {
                out.push('"');
                out.push_str(a);
                out.push('"');
            } else {
                out.push_str(a);
            }
        }
        out
    }

    /// 第 3 层：`cmd /c` 对余下命令行的引号处理（Windows 文档里 /C 的那两条规则）。
    /// 这里 `exe_exists` 恒为 false：测试环境里没有真的 pi 可执行文件，
    /// 而规则 1 只在「两个引号之间是已存在的可执行文件」时才生效。
    fn cmd_c_slice(remainder: &str) -> String {
        let quote_count = remainder.chars().filter(|&c| c == '"').count();
        if !remainder.starts_with('"') {
            return remainder.to_string();
        }
        if quote_count == 2 {
            // 规则 1：仅当两个引号之间是已存在的可执行文件时保留引号
            let inner: String = remainder.trim_matches('"').to_string();
            let has_space = inner.chars().any(|c| c.is_whitespace());
            let special = inner.chars().any(|c| "&<>()@^|".contains(c));
            let _ = (has_space, special); // 测试里 exe 不存在 → 落到规则 2
        }
        // 规则 2：剥掉开头与结尾各一个引号
        let mut chars: Vec<char> = remainder.chars().collect();
        if chars.first() == Some(&'"') {
            chars.remove(0);
        }
        if chars.last() == Some(&'"') {
            chars.pop();
        }
        chars.into_iter().collect()
    }

    /// `^%` 换出来的字面百分号用的占位符，展开完再换回去
    const PERCENT: char = '\u{1}';

    /// cmd 的词法：引号内一切字面；引号外 `^` 吞掉下一个字符，
    /// 被 `^` 保护的 `%` 不会被当成变量引用（用占位符带出去）。
    fn cmd_lex(line: &str) -> String {
        let chars: Vec<char> = line.chars().collect();
        let mut out = String::new();
        let mut in_quotes = false;
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if c == '"' {
                in_quotes = !in_quotes;
                out.push(c);
                i += 1;
                continue;
            }
            if !in_quotes && c == '^' && i + 1 < chars.len() {
                let next = chars[i + 1];
                out.push(if next == '%' { PERCENT } else { next });
                i += 2;
                continue;
            }
            out.push(c);
            i += 1;
        }
        out
    }

    /// 模拟 `%NAME%` 展开：只认真实存在的环境变量名，其余 `%` 保持字面；
    /// 展开完成后再把 `^%` 带出来的占位符换回字面百分号。
    fn expand_percent(line: &str, env: &[(&str, &str)]) -> String {
        let mut out = line.to_string();
        for (name, value) in env {
            out = out.replace(&format!("%{name}%"), value);
        }
        out.replace(PERCENT, "%")
    }

    /// 走完整条链，返回子进程真正拿到的 argv
    fn child_argv(args: &[String], env: &[(&str, &str)]) -> Vec<String> {
        let wire = encode_create_process(args);
        let wt_argv = argv_from_commandline(&wire);
        assert_eq!(wt_argv, args.to_vec(), "wt 收到的 argv 被打乱了：{wire}");

        // wt 的 Commandline::AddArg 会把 `\;` 还原成 `;`
        let unescaped: Vec<String> = wt_argv[5..]
            .iter()
            .map(|a| a.replace("\\;", ";"))
            .collect();
        // `-w new new-tab -d <dir>` 之后的才是 profile 命令行
        let positionals = &unescaped[..];
        assert_eq!(positionals[0], "cmd.exe");
        let joined = wt_join(positionals);
        let after_c = joined.split_once("/c ").expect("没有 /c").1.to_string();
        let sliced = cmd_c_slice(&after_c);
        let lexed = cmd_lex(&sliced);
        let expanded = expand_percent(&lexed, env);
        argv_from_commandline(&expanded)
    }

    #[test]
    fn full_chain_reaches_pi_with_exact_argv() {
        let cases: Vec<(&str, Option<&str>, &str)> = vec![
            (r"C:\Users\demo\proj", None, "pi"),
            (r"C:\Users\demo\proj", Some(r"C:\Users\demo\.pi\agent\sessions\--C--Users-demo-proj--\a.jsonl"), "pi"),
            (r"C:\Users\张三\项目 'A'\sub", Some(r"C:\Users\张三\.pi\a b.jsonl"), "pi"),
            (r"D:\work & test\a;b\dir", Some(r"D:\work & test\s 'x' ; v2.jsonl"), "pi"),
            (r"C:\path with ^caret & pipe|dir", Some(r"C:\caret^path\s.jsonl"), "pi"),
            (r"C:\100%done\dir", Some(r"C:\100%done\s;1.jsonl"), "pi"),
            (r"C:\Users\John Doe\proj", Some(r"C:\Users\John Doe\.pi\s.jsonl"), r"C:\Program Files\Pi\pi.cmd"),
            (r"C:\Users\demo\proj", Some(r"C:\Users\demo\s!x!.jsonl"), "pi"),
            // 反斜杠紧挨着 `%`：不补偶数个反斜杠的话 `\"` 会被当成字面引号，整个 token 散架
            (r"C:\proj\%TEMP%x", Some(r"C:\users\demo\%PATH%\s.jsonl"), "pi"),
            // 结尾反斜杠（盘符根、以 `\` 收尾的目录）
            (r"C:\", Some("C:\\s\\tail\\"), "pi"),
        ];

        for (project, session, pi) in cases {
            let args = build_wt_args(project, session, pi).unwrap();
            let got = child_argv(&args, &[]);
            let mut want: Vec<String> = vec![pi.to_string()];
            if let Some(s) = session {
                want.push("--session".to_string());
                want.push(s.to_string());
            }
            assert_eq!(got, want, "project={project} session={session:?} pi={pi}");
        }
    }

    #[test]
    fn environment_variables_in_paths_are_not_expanded() {
        // 名字和环境变量同形的路径必须原样落地，不能被 cmd 当成变量展开
        let project = r"C:\proj\%TEMP%x";
        let session = r"C:\users\demo\%PATH%\s.jsonl";
        let args = build_wt_args(project, Some(session), "pi").unwrap();
        let got = child_argv(&args, &[("TEMP", "ZZZ"), ("PATH", "QQQ")]);
        assert_eq!(
            got,
            vec![
                "pi".to_string(),
                "--session".to_string(),
                r"C:\users\demo\%PATH%\s.jsonl".to_string()
            ],
            "路径里的 %PATH% 被展开了"
        );

        // 对照：没被 `^` 保护的同一个串确实会被展开，证明这条断言不是空转
        assert_eq!(
            expand_percent(r"C:\users\demo\%PATH%\s.jsonl", &[("PATH", "QQQ")]),
            r"C:\users\demo\QQQ\s.jsonl"
        );

        // 项目目录走 -d，不进 cmd，但分号仍要转义给 wt
        assert!(args[4].contains(r"\;") || !args[4].contains(';'));
    }

    #[test]
    fn rejects_unpassable_input() {
        assert!(cmd_quote_arg("bad\npath").is_err());
        assert!(cmd_quote_arg("bad\rpath").is_err());
        assert!(cmd_quote_arg("bad\"path").is_err());
        assert!(cmd_quote_arg("").is_ok());
    }
}
