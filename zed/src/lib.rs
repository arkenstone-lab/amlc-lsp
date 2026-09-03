use zed_extension_api::{self as zed, Result};

struct AmlExtension;

impl zed::Extension for AmlExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &zed::LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let command = worktree
            .which("amlc-lsp")
            .ok_or_else(|| "amlc-lsp was not found on PATH; install it with `opam install amlc-lsp` and ensure a compatible `amlc` is available".to_string())?;

        Ok(zed::Command {
            command,
            args: Vec::new(),
            env: Default::default(),
        })
    }
}

zed::register_extension!(AmlExtension);
